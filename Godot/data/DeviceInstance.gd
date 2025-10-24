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

## Set the enabled state of this device instance (sends to engine)
func set_enabled(p_enabled : bool) -> void:
	if enabled == p_enabled:
		return
	# we only send to engine, we don't update our own state - we do this on engine callback
	AudioEngineOSC.send("/channel/%d/device/%d/enable" % [channel_id, position], [1 if p_enabled else 0])

## Set the active state of this device instance (sends to engine)
func set_active(p_active : bool) -> void:
	if active == p_active:
		return
	
	AudioEngineOSC.send("/channel/%d/device/%d/activate" % [channel_id, position], [1 if p_active else 0])


## Open the native GUI for this device (if supported)
func open_gui() -> void:
	if not device.has_gui():
		push_warning("[DeviceInstance] Device %s does not have a native GUI" % device.name)
		return
	
	if active:
		AudioEngineOSC.send("/channel/%d/device/%d/gui/open" % [channel_id, position], [])


## Close the native GUI for this device (if supported)
func close_gui() -> void:
	if not device.has_gui():
		return
	
	AudioEngineOSC.send("/channel/%d/device/%d/gui/close" % [channel_id, position], [])


## Connect to audio engine: listen for state updates
func connect_to_engine() -> void:
	var active_addr = "/channel/%d/device/%d/active" % [channel_id, position]
	var enabled_addr = "/channel/%d/device/%d/enabled" % [channel_id, position]
	
	AudioEngineOSC.listen(active_addr, _on_active_received)
	AudioEngineOSC.listen(enabled_addr, _on_enabled_received)


## Disconnect from audio engine: stop listening
func disconnect_from_engine() -> void:
	var active_addr = "/channel/%d/device/%d/active" % [channel_id, position]
	var enabled_addr = "/channel/%d/device/%d/enabled" % [channel_id, position]
	
	AudioEngineOSC.unlisten(active_addr, _on_active_received)
	AudioEngineOSC.unlisten(enabled_addr, _on_enabled_received)


## ============================================================================
## OSC CALLBACKS (from engine)
## ============================================================================

func _on_active_received(values: Array) -> void:
	"""Handle active state update from engine (don't send back to avoid loop)."""
	if values.size() >= 1:
		var new_active = values[0] != 0
		if active != new_active:
			active = new_active
			active_changed.emit(active)


func _on_enabled_received(values: Array) -> void:
	"""Handle enabled state update from engine (don't send back to avoid loop)."""
	if values.size() >= 1:
		var new_enabled = values[0] != 0
		if enabled != new_enabled:
			enabled = new_enabled
			enabled_changed.emit(enabled)

## Sync this device instance's parameters to the audio engine (bulk sync)
## TODO: Implement this
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
## SERIALIZATION
## ============================================================================

## Serialize to JSON
func to_json() -> Dictionary:
	return {
		"id": id,
		"device_id": device.id,
		"channel_id": channel_id,
		"position": position,
		"active": active,
		"enabled": enabled,
		"parameter_values": parameter_values
	}


## Deserialize from JSON
static func from_json(data: Dictionary) -> DeviceInstance:
	var device_id = data.get("device_id", "")
	var device = AssetService.get_device(device_id)
	
	if not device:
		push_error("[DeviceInstance] Failed to load device: " + device_id)
		return null
	
	var chan_id = data.get("channel_id", 0)
	var pos = data.get("position", 0)
	var is_active = data.get("active", true)
	var is_enabled = data.get("enabled", true)
	
	var instance = DeviceInstance.new(device, chan_id, pos, is_active, is_enabled)
	instance.id = data.get("id", instance.id)  # Restore original ID
	
	# Restore parameter values
	var param_values = data.get("parameter_values", {})
	for param_id_str in param_values.keys():
		var param_id = int(param_id_str) if param_id_str is String else param_id_str
		instance.parameter_values[param_id] = param_values[param_id_str]
	
	return instance


## ============================================================================
## DISPLAY HELPERS
## ============================================================================

## Get display name (device name + position)
## DEPRECATED: just use device.name instead
func get_display_name() -> String:
	return device.name
