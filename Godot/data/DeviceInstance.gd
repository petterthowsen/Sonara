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
signal parameters_updated()  # Emitted when parameter list changes (e.g., SFZ file loaded)
signal loading_state_changed(state: String)  # "idle", "loading", "ready", "failed:{error}"


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

## Track loaded file path (for devices that support file loading, e.g., SFZ sampler)
var loaded_file_path: String = ""

## Loading state: "idle", "loading", "ready", "failed:{error}"
var loading_state: String = "idle"

## Track expected parameter count when receiving parameter info
var _expected_param_count: int = 0


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
	if device == null:
		push_error("[DeviceInstance] Created with null device (channel=%d, position=%d)" % [channel_id, position])
		return
	for param in device.get_parameters():
		parameter_values[param.id] = param.value_to_normalized(param.default_value)


## ============================================================================
## PARAMETER MANAGEMENT
## ============================================================================

## Set a parameter value (normalized 0.0-1.0)
## This is called from UI controls and syncs to the engine.
## Does NOT emit signal - signal is emitted when engine echoes back via OSC.
## This ensures server is the single source of truth.
func set_parameter_normalized(param_id: int, normalized_value: float) -> void:
	if param_id in parameter_values:
		var new_value = clamp(normalized_value, 0.0, 1.0)
		var old_value = parameter_values[param_id]
		
		# Only sync if value actually changed
		if abs(old_value - new_value) > 0.0001:
			# Update local cache (for immediate visual feedback)
			parameter_values[param_id] = new_value

			var param = device.get_parameter(param_id)
			if param and not param.syncable:
				# UI-local parameter: emit immediately, do not send OSC
				parameter_changed.emit(param_id, parameter_values[param_id])
			else:
				# Sync to engine - it will echo back and we'll emit signal then
				sync_parameter_to_engine(param_id)


## Get a parameter value (normalized 0.0-1.0)
func get_parameter_normalized(param_id: int) -> float:
	return parameter_values.get(param_id, 0.5)


## Get parameter ID by name (case-insensitive). Returns -1 if not found
func get_parameter_id_by_name(param_name: String) -> int:
	if device == null:
		return -1
	var p = device.get_parameter_by_name(param_name)
	return p.id if p else -1


## Get parameter value (normalized) by name. Returns 0.5 if not found
func get_parameter_normalized_by_name(param_name: String) -> float:
	var pid = get_parameter_id_by_name(param_name)
	return get_parameter_normalized(pid) if pid >= 0 else 0.5


## Set parameter value (normalized) by name
func set_parameter_normalized_by_name(param_name: String, normalized_value: float) -> void:
	var pid = get_parameter_id_by_name(param_name)
	if pid >= 0:
		set_parameter_normalized(pid, normalized_value)


## Get parameter value (real) by name
func get_parameter_real_by_name(param_name: String) -> float:
	if device == null:
		return 0.0
	var param = device.get_parameter_by_name(param_name)
	if param:
		var normalized = get_parameter_normalized(param.id)
		return param.normalized_to_value(normalized)
	return 0.0


## Set parameter value (real) by name
func set_parameter_real_by_name(param_name: String, real_value: float) -> void:
	if device == null:
		return
	var param = device.get_parameter_by_name(param_name)
	if param:
		var normalized = param.value_to_normalized(real_value)
		set_parameter_normalized(param.id, normalized)


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


## =========================================================================
## VIEW FACTORY
## =========================================================================

## Create a DeviceView instance for the requested view type using
## Device's PackedScene registrations. Returns null if unsupported.
func create_view(view_type: Device.ViewType) -> DeviceView:
	if device == null:
		return null

	var scene: PackedScene = null
	match view_type:
		Device.ViewType.Panel:
			scene = device.panel_view_scene
		Device.ViewType.Large:
			scene = device.large_view_scene
		Device.ViewType.Auxiliary:
			scene = device.auxiliary_view_scene
		Device.ViewType.Compact:
			scene = device.compact_view_scene
		_:
			scene = null

	if scene == null:
		return null

	var inst = scene.instantiate()
	if not inst is DeviceView:
		push_error("[DeviceInstance] View scene must extend DeviceView")
		inst.queue_free()
		return null

	# Annotate the view type if supported
	if inst.has_method("set_view_type"):
		inst.set_view_type(view_type)

	return inst


## Connect to audio engine: listen for state updates
func connect_to_engine() -> void:
	var active_addr = "/channel/%d/device/%d/active" % [channel_id, position]
	var enabled_addr = "/channel/%d/device/%d/enabled" % [channel_id, position]
	var param_count_addr = "/channel/%d/device/%d/param/count" % [channel_id, position]
	var param_info_addr = "/channel/%d/device/%d/param/info" % [channel_id, position]
	var loading_state_addr = "/channel/%d/device/%d/loading_state" % [channel_id, position]
	
	AudioEngineOSC.listen(active_addr, _on_active_received)
	AudioEngineOSC.listen(enabled_addr, _on_enabled_received)
	AudioEngineOSC.listen(param_count_addr, _on_param_count_received)
	AudioEngineOSC.listen(param_info_addr, _on_param_info_received)
	AudioEngineOSC.listen(loading_state_addr, _on_loading_state_received)
	
	# Use wildcard pattern to listen for ALL parameter changes for this device
	var param_pattern = "/channel/%d/device/%d/param/*/value" % [channel_id, position]
	AudioEngineOSC.listen(param_pattern, _on_parameter_value_received_wildcard)
	
	# If this device had a file loaded, reload it after engine connection
	if loaded_file_path != "":
		print("[DeviceInstance] Reloading file after engine connection: %s" % loaded_file_path)
		AudioEngineOSC.send("/channel/%d/device/%d/load_file" % [channel_id, position], [loaded_file_path])


## Disconnect from audio engine: stop listening
func disconnect_from_engine() -> void:
	var active_addr = "/channel/%d/device/%d/active" % [channel_id, position]
	var enabled_addr = "/channel/%d/device/%d/enabled" % [channel_id, position]
	var param_count_addr = "/channel/%d/device/%d/param/count" % [channel_id, position]
	var param_info_addr = "/channel/%d/device/%d/param/info" % [channel_id, position]
	var param_pattern = "/channel/%d/device/%d/param/*/value" % [channel_id, position]
	var loading_state_addr = "/channel/%d/device/%d/loading_state" % [channel_id, position]
	
	AudioEngineOSC.unlisten(active_addr, _on_active_received)
	AudioEngineOSC.unlisten(enabled_addr, _on_enabled_received)
	AudioEngineOSC.unlisten(param_count_addr, _on_param_count_received)
	AudioEngineOSC.unlisten(param_info_addr, _on_param_info_received)
	AudioEngineOSC.unlisten(param_pattern, _on_parameter_value_received_wildcard)
	AudioEngineOSC.unlisten(loading_state_addr, _on_loading_state_received)


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


func _on_loading_state_received(values: Array) -> void:
	"""Handle loading state update from engine."""
	if values.size() >= 1:
		var new_state = str(values[0])
		if loading_state != new_state:
			loading_state = new_state
			loading_state_changed.emit(loading_state)
			
			# Log state changes for debugging
			if loading_state.begins_with("failed:"):
				push_error("[DeviceInstance %s] Loading failed: %s" % [device.name, loading_state])
			elif loading_state == "ready":
				print("[DeviceInstance %s] Loading complete" % device.name)


func _on_parameter_value_received_wildcard(values: Array, address: String) -> void:
	"""Handle parameter value changes via wildcard pattern.
	Parse param_id from the OSC address: /channel/X/device/Y/param/ID/value"""
	# Parse parameter ID from address: /channel/2/device/1/param/5/value -> 5
	var parts = address.split("/")
	if parts.size() < 7:
		push_warning("[DeviceInstance] Invalid parameter address format: %s" % address)
		return
	
	var param_id = int(parts[6])  # parts[6] is the parameter ID
	_on_parameter_value_received(values, param_id)


func _on_parameter_value_received(values: Array, param_id: int) -> void:
	"""Handle parameter value changes from the engine (all changes, including echoes).
	This is the ONLY place we emit parameter_changed signal, ensuring server is source of truth.
	Receives both: echoes of our UI changes AND plugin-initiated changes (GUI, preset, modulation)."""
	if values.size() < 1:
		return
	
	var new_value = float(values[0])
	
	# Update parameter if it exists
	if param_id not in parameter_values:
		push_warning("[DeviceInstance] Received update for unknown parameter %d" % param_id)
		return
	
	var old_value = parameter_values[param_id]
	if abs(old_value - new_value) > 0.0001:  # Floating point tolerance
		parameter_values[param_id] = clamp(new_value, 0.0, 1.0)
		
		# Always emit signal - this is the single source of truth for all parameter changes
		parameter_changed.emit(param_id, parameter_values[param_id])


func _on_param_count_received(args: Array) -> void:
	"""Handle parameter count message from engine (start of parameter list)."""
	if args.size() < 1:
		push_warning("[DeviceInstance %s] Invalid param count message" % device.name)
		return
	
	var count: int = args[0]
	_expected_param_count = count
	
	# Clear existing parameters when we receive a new count
	# This handles cases where parameters change (e.g., SFZ file loaded)
	device.parameters.clear()
	parameter_values.clear()
	
	print("[DeviceInstance %s] Expecting %d parameters" % [device.name, count])


func _on_param_info_received(args: Array) -> void:
	"""Handle parameter info message from engine."""
	if args.size() < 5:
		push_warning("[DeviceInstance %s] Invalid param info message" % device.name)
		return
	
	var param_id: int = args[0]
	var param_name: String = args[1]
	var min_val: float = args[2]
	var max_val: float = args[3]
	var default_val: float = args[4]
	
	# Create DeviceParameter and add to device
	var param = DeviceParameter.new(param_id, param_name, "")
	param.min_value = min_val
	param.max_value = max_val
	param.default_value = default_val
	device.add_parameter(param)
	
	# Initialize parameter value
	parameter_values[param_id] = param.value_to_normalized(default_val)
	
	print("[DeviceInstance %s] Param %d: %s [%.2f - %.2f, default %.2f]" % 
		[device.name, param_id, param_name, min_val, max_val, default_val])
	
	# Check if we've received all expected parameters
	if device.parameters.size() >= _expected_param_count and _expected_param_count > 0:
		print("[DeviceInstance %s] All %d parameters loaded" % [device.name, _expected_param_count])
		_expected_param_count = 0  # Reset
		parameters_updated.emit()


## Sync this device instance's parameters to the audio engine (bulk sync)
## TODO: Implement this
func sync_to_engine() -> void:
	for param_id in parameter_values:
		var param = device.get_parameter(param_id)
		if param and not param.syncable:
			continue
		var normalized_value = parameter_values[param_id]
		if param and param.param_type == "bool":
			var idx: int = 1 if normalized_value >= 0.5 else 0
			AudioEngineOSC.send("/channel/%d/device/%d/param/%d" % [channel_id, position, param_id], [idx])
		elif param and param.param_type == "enum":
			var n: int = max(1, param.enum_values.size())
			var idx: int = int(round(normalized_value * float(n - 1)))
			AudioEngineOSC.send("/channel/%d/device/%d/param/%d" % [channel_id, position, param_id], [idx])
		else:
			AudioEngineOSC.send("/channel/%d/device/%d/param/%d" % [channel_id, position, param_id], [normalized_value])


## Sync a single parameter to the audio engine
func sync_parameter_to_engine(param_id: int) -> void:
	if param_id in parameter_values:
		var param = device.get_parameter(param_id)
		if param and not param.syncable:
			return
		var normalized_value = parameter_values[param_id]
		if param and param.param_type == "bool":
			var idx: int = 1 if normalized_value >= 0.5 else 0
			print("[DeviceInstance] send BOOL param_id=", param_id, " idx=", idx)
			AudioEngineOSC.send("/channel/%d/device/%d/param/%d" % [channel_id, position, param_id], [idx])
		elif param and param.param_type == "enum":
			var n: int = max(1, param.enum_values.size())
			var idx: int = int(round(normalized_value * float(n - 1)))
			print("[DeviceInstance] send ENUM param_id=", param_id, " idx=", idx, " n=", n, " normalized=", normalized_value)
			AudioEngineOSC.send("/channel/%d/device/%d/param/%d" % [channel_id, position, param_id], [idx])
		else:
			print("[DeviceInstance] send FLOAT param_id=", param_id, " normalized=", normalized_value)
			AudioEngineOSC.send("/channel/%d/device/%d/param/%d" % [channel_id, position, param_id], [normalized_value])


## Load a file into this device (e.g., SFZ file into sfizz sampler)
func load_file(file_path: String) -> void:
	if not device.supports_file_loading:
		push_error("[DeviceInstance] Device %s does not support file loading" % device.name)
		return
	
	print("[DeviceInstance] Loading file into %s: %s" % [device.name, file_path])
	loaded_file_path = file_path
	AudioEngineOSC.send("/channel/%d/device/%d/load_file" % [channel_id, position], [file_path])


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
		"parameter_values": parameter_values,
		"loaded_file_path": loaded_file_path
	}


## Deserialize from JSON
static func from_json(data: Dictionary) -> DeviceInstance:
	var device_id = data.get("device_id", "")
	var loaded_device = AssetService.get_device(device_id)
	
	if not loaded_device:
		print("[DeviceInstance] Device not found (may need plugin scan): %s" % device_id)
		return null
	
	var chan_id = data.get("channel_id", 0)
	var pos = data.get("position", 0)
	var is_active = data.get("active", true)
	var is_enabled = data.get("enabled", true)
	
	var instance = DeviceInstance.new(loaded_device, chan_id, pos, is_active, is_enabled)
	instance.id = data.get("id", instance.id)  # Restore original ID
	
	# Restore parameter values
	var param_values = data.get("parameter_values", {})
	for param_id_str in param_values.keys():
		var param_id = int(param_id_str) if param_id_str is String else param_id_str
		instance.parameter_values[param_id] = param_values[param_id_str]
	
	# Restore loaded file path (will be reloaded after engine connection)
	instance.loaded_file_path = data.get("loaded_file_path", "")
	
	return instance


## ============================================================================
## DISPLAY HELPERS
## ============================================================================

## Get display name (device name + position)
## DEPRECATED: just use device.name instead
func get_display_name() -> String:
	return device.name
