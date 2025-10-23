## DeviceInstance.gd
## Represents an instance of a device on a channel (with parameter state).
## Tracks current parameter values and handles syncing with the audio engine.

class_name DeviceInstance extends RefCounted

## ============================================================================
## SIGNALS
## ============================================================================

signal parameter_changed(param_id: int, value: float)

signal enabled_changed(enabled: bool)
signal active_changed(active: bool)


## ============================================================================
## PROPERTIES
## ============================================================================

## Unique instance identifier (UUID)
var id: String = ""

## The device type (metadata)
var device: Device

## Channel this device is on
var channel_id: int = 0

## Whether this device is active (loaded into memory)
var active : bool = true

## Whether this device is enabled (effectively processing audio vs bypassed)
var enabled : bool = true

## Position in the device chain (0 = first)
var position: int = 0

## Current parameter values (normalized 0.0-1.0)
var parameter_values: Dictionary[int, float] = {}


## ============================================================================
## INITIALIZATION
## ============================================================================

func _init(p_device: Device, p_channel_id: int, p_position: int, p_active: bool = true, p_enabled: bool = true) -> void:
	id = str(randi_range(0, 2147483647)).pad_zeros(10)  # Simple UUID
	device = p_device
	channel_id = p_channel_id
	position = p_position
	active = p_active
	enabled = p_enabled

	# Initialize all parameters to default normalized values
	for param in device.get_parameters():
		parameter_values[param.id] = param.value_to_normalized(param.default_value)


## ============================================================================
## PARAMETER MANAGEMENT
## ============================================================================

## Set a parameter value (normalized 0.0-1.0)
func set_parameter_normalized(param_id: int, normalized_value: float) -> void:
	if param_id in parameter_values:
		parameter_values[param_id] = clamp(normalized_value, 0.0, 1.0)
		parameter_changed.emit(param_id, parameter_values[param_id])


## Get a parameter value (normalized 0.0-1.0)
func get_parameter_normalized(param_id: int) -> float:
	return parameter_values.get(param_id, 0.5)


## Set a parameter value (real range)
func set_parameter_real(param_id: int, real_value: float) -> void:
	var param = device.get_parameter(param_id)
	if param:
		var normalized = param.value_to_normalized(real_value)
		set_parameter_normalized(param_id, normalized)


## Get a parameter value (real range)
func get_parameter_real(param_id: int) -> float:
	var param = device.get_parameter(param_id)
	if param:
		var normalized = get_parameter_normalized(param_id)
		return param.normalized_to_value(normalized)
	return 0.5


## Get all parameter values as a dictionary (for UI)
func get_all_parameters_normalized() -> Dictionary[int, float]:
	return parameter_values.duplicate()


## ============================================================================
## SYNC WITH ENGINE
## ============================================================================

## Set the enabled state of this device instance
func set_enabled(p_enabled : bool) -> void:
	if enabled == p_enabled:
		return
	
	enabled = p_enabled
	AudioEngineOSC.send("/channel/%d/device/%d/enable" % [channel_id, position], [1 if enabled else 0])
	enabled_changed.emit(enabled)

## Set the active state of this device instance
func set_active(p_active : bool) -> void:
	if active == p_active:
		return
	
	active = p_active
	AudioEngineOSC.send("/channel/%d/device/%d/activate" % [channel_id, position], [1 if active else 0])
	active_changed.emit(active)

## Sync this device instance's parameters to the audio engine (bulk sync)
## TODO: 
func sync_to_engine() -> void:
	for param_id in parameter_values:
		var normalized_value = parameter_values[param_id]
		AudioEngineOSC.send("/channel/%d/device/%d/param/%d" % [channel_id, position, param_id], [normalized_value])


## Sync a single parameter to the audio engine
func sync_parameter_to_engine(param_id: int) -> void:
	if param_id in parameter_values:
		var normalized_value = parameter_values[param_id]
		AudioEngineOSC.send("/channel/%d/device/%d/param/%d" % [channel_id, position, param_id], [normalized_value])


## ============================================================================
## DISPLAY HELPERS
## ============================================================================

## Get display name (device name + position)
## DEPRECATED: just use device.name instead
func get_display_name() -> String:
	return device.name
