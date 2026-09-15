## DeviceInstance.gd
## Represents an instance of a device on a channel (with parameter state).
## Tracks current parameter values and handles syncing with the audio engine.

class_name DeviceInstance extends RefCounted

static var logger := Log.make("DeviceInstance")

## ============================================================================
## SIGNALS
## ============================================================================

signal parameter_changed(param_id: int, value: float)
signal enabled_changed(enabled: bool)
signal active_changed(active: bool)
signal parameters_updated()  # Emitted when parameter list changes (e.g., SFZ file loaded)
signal loading_state_changed(state: String)  # "idle", "loading", "ready", "failed:{error}"
signal plugin_gui_closed()  # Emitted when plugin GUI window is closed
signal child_added(device_instance: DeviceInstance, position: int)
signal child_removed(position: int, device_id: String)
signal child_moved(from_position: int, to_position: int)
signal slot_changed()
signal name_changed(new_name: String)


## ============================================================================
## PROPERTIES
## ============================================================================

## Unique instance identifier (UUID)
var id: String = ""

## Display name for this instance (sibling-unique on a host). Empty until assigned.
var name: String = ""

## The device type (metadata)
var device: Device

## Channel this device is on
var channel_id: int = 0

## Whether this device is active (loaded into memory)
var active : bool = true

## Whether this device is enabled (effectively processing audio vs bypassed)
var enabled : bool = true

## Position in the parent device list (0 = first)
var position: int = 0

## Nested child devices when this instance is a container (Chain/Layer).
var children: Array[DeviceInstance] = []

## Weak parent container; unset at the channel root.
var _parent_ref: WeakRef = null

## Weak channel this instance is attached to (for sibling names and paths).
var _channel_ref: WeakRef = null

## Layer slot mix controls (used when the parent is a Layer).
var slot_volume: float = 0.5
var slot_mute: bool = false
var slot_solo: bool = false

## MIDI note for a Drum Machine child (-1 = unset, engine assigns).
var slot_note: int = -1

## Mixer channel that receives this pad's extra-out bus (-1 = none).
var return_channel_id: int = -1

## Extra-out return channels for a multi-out plugin (index = extra stereo bus).
var return_channel_ids: Array[int] = []

## Return channels removed along with this device (or pad), kept by id so re-adding the same
## instance (undo, move) restores them with their settings. Not persisted. See AuxReturnSync.
var detached_returns: Dictionary[int, Channel] = {}

## Waveform pyramid when this instance is a Sampler (or other sample-loading device).
var sample_waveform: WaveformPyramid = null

## Current parameter values (normalized 0.0-1.0)
var parameter_values: Dictionary[int, float] = {}

## Parameter metadata advertised by the engine for THIS instance (SFZ/CLAP
## devices whose param list depends on the loaded file/plugin instance).
## Empty for built-ins with a static param list defined on the shared
## `Device` registry object; use get_parameter()/get_parameters() etc.
## instead of reaching into `device.parameters` directly, since that object
## is shared by every instance of the same device type and must not be
## overwritten per-instance.
var parameters: Array[DeviceParameter] = []

## Track loaded file path (for devices that support file loading, e.g., SFZ sampler)
var loaded_file_path: String = ""

## Loading state: "idle", "loading", "ready", "failed:{error}"
var loading_state: String = "idle"

## Track expected parameter count when receiving parameter info
var _expected_param_count: int = 0

## Parameter values restored from a project file, reapplied after the engine advertises params.
## SFZ/CLAP devices wipe and rebuild their parameter list on load; this keeps saved CC/param values.
var _restored_parameter_values: Dictionary[int, float] = {}

## Guards against double-registering OSC listeners (connect_to_engine can be
## called both from Channel.connect_to_engine() and Channel.add_device()).
var _is_connected: bool = false


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
	for param in get_parameters():
		parameter_values[param.id] = param.value_to_normalized(param.default_value)


## Assign a path-safe, sibling-unique display name. Emits `name_changed` when it differs.
func set_name(new_name: String) -> void:
	var fallback := device.name if device and not device.name.is_empty() else "Device"
	var unique := DeviceNaming.unique_in(_sibling_names(), new_name, fallback)
	if unique == name:
		return
	name = unique
	name_changed.emit(name)


## Names of siblings on the same host, excluding this instance.
func _sibling_names() -> PackedStringArray:
	var out: PackedStringArray = []
	for d in _sibling_host():
		if d != self and d is DeviceInstance:
			out.append(d.name)
	return out


## Parent children, or the channel root device list when this instance is at the root.
func _sibling_host() -> Array[DeviceInstance]:
	var parent := get_parent_device()
	if parent:
		return parent.children
	var ch := get_channel()
	if ch:
		return ch.devices
	return []


## Mixer channel this instance is on, if still alive.
func get_channel() -> Channel:
	if _channel_ref == null:
		return null
	return _channel_ref.get_ref() as Channel


## Record the owning channel (weak, to avoid RefCounted cycles).
func set_channel(channel: Channel) -> void:
	_channel_ref = weakref(channel) if channel else null


## ============================================================================
## PARAMETER MANAGEMENT
## ============================================================================

## Get parameter metadata by ID: prefers this instance's own advertised
## parameters (SFZ/CLAP) and falls back to the shared Device registry
## (built-ins with a static param list).
func get_parameter(param_id: int) -> DeviceParameter:
	if not parameters.is_empty():
		for param in parameters:
			if param.id == param_id:
				return param
		return null
	return device.get_parameter(param_id) if device else null


## Get parameter metadata by name (case-insensitive), instance-first.
func get_parameter_by_name(param_name: String) -> DeviceParameter:
	if not parameters.is_empty():
		var target = param_name.strip_edges().to_lower()
		for param in parameters:
			if String(param.name).to_lower() == target:
				return param
		return null
	return device.get_parameter_by_name(param_name) if device else null


## All parameter metadata for this instance, instance-first.
func get_parameters() -> Array[DeviceParameter]:
	if not parameters.is_empty():
		return parameters
	return device.get_parameters() if device else []


## Parameters in a UI group ("param" or "cc"), instance-first.
func get_parameters_in_group(group: String) -> Array[DeviceParameter]:
	var source := get_parameters()
	var result: Array[DeviceParameter] = []
	for param in source:
		var param_group = param.group if param.group != "" else "param"
		if param_group == group:
			result.append(param)
	return result


## True when this instance advertises at least one CC-tab parameter.
func has_cc_parameters() -> bool:
	return not get_parameters_in_group("cc").is_empty()


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

			var param = get_parameter(param_id)
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
	var p = get_parameter_by_name(param_name)
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
	var param = get_parameter_by_name(param_name)
	if param:
		var normalized = get_parameter_normalized(param.id)
		return param.normalized_to_value(normalized)
	return 0.0


## Set parameter value (real) by name
func set_parameter_real_by_name(param_name: String, real_value: float) -> void:
	if device == null:
		return
	var param = get_parameter_by_name(param_name)
	if param:
		var normalized = param.value_to_normalized(real_value)
		set_parameter_normalized(param.id, normalized)


## Set a parameter value (real range)
func set_parameter_real(param_id: int, real_value: float) -> void:
	var param = get_parameter(param_id)
	if param:
		var normalized = param.value_to_normalized(real_value)
		set_parameter_normalized(param_id, normalized)


## True when this instance can own nested devices.
func is_container() -> bool:
	return device != null and device.is_container


## True when `other` is this instance or a nested descendant.
func contains_device(other: DeviceInstance) -> bool:
	if other == null:
		return false
	if other == self:
		return true
	for child in children:
		if child.contains_device(other):
			return true
	return false


## Parent container, or null at the channel root.
func get_parent_device() -> DeviceInstance:
	if _parent_ref == null:
		return null
	return _parent_ref.get_ref() as DeviceInstance


## Record the parent container (weak, to avoid RefCounted cycles).
func set_parent_device(parent: DeviceInstance) -> void:
	_parent_ref = weakref(parent) if parent else null


## OSC prefix `/channel/{id}/device/{i0}/child/{i1}` with no trailing action.
func osc_path() -> String:
	var indices: Array[int] = []
	var current: DeviceInstance = self
	while current:
		indices.insert(0, current.position)
		current = current.get_parent_device()
	if indices.is_empty():
		return "/channel/%d/device/%d" % [channel_id, position]
	var path := "/channel/%d/device/%d" % [channel_id, indices[0]]
	for i in range(1, indices.size()):
		path += "/child/%d" % indices[i]
	return path


## Full OSC address for an action on this device (`enable`, `param/0`, ...).
func osc_addr(action: String) -> String:
	if action.is_empty():
		return osc_path()
	return "%s/%s" % [osc_path(), action]


## Index path from the channel root, e.g. `"0/1"`.
func path_string() -> String:
	var indices: Array[int] = []
	var current: DeviceInstance = self
	while current:
		indices.insert(0, current.position)
		current = current.get_parent_device()
	return "/".join(indices.map(func(i): return str(i)))


## Rebind OSC listeners after this instance's path changes.
func reconnect_to_engine() -> void:
	disconnect_from_engine()
	if channel_id >= 0:
		connect_to_engine()


## Get a parameter value (real range)
func get_parameter_real(param_id: int) -> float:
	var param = get_parameter(param_id)
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
	AudioEngineOSC.send(osc_addr("enable"), [1 if p_enabled else 0])

## Set the active state of this device instance (sends to engine)
func set_active(p_active : bool) -> void:
	if active == p_active:
		return
	
	AudioEngineOSC.send(osc_addr("activate"), [1 if p_active else 0])


## Open the native GUI for this device (if supported)
func open_gui() -> void:
	if not device.has_gui():
		push_warning("[DeviceInstance] Device %s does not have a native GUI" % device.name)
		return
	
	if active:
		AudioEngineOSC.send(osc_addr("gui/open"), [])


## Close the native GUI for this device (if supported)
func close_gui() -> void:
	if not device.has_gui():
		return
	
	AudioEngineOSC.send(osc_addr("gui/close"), [])


## Connect to audio engine and listen for state updates.
## Registers OSC listeners only; the file (if any) is loaded with a proper
## req_id by Channel.sync_to_engine()/_sync_device_tree_to_engine(), which
## runs whenever this instance is synced to the engine (project load,
## channel connect, or add_device while already connected).
func connect_to_engine() -> void:
	if _is_connected:
		return
	_is_connected = true

	var active_addr = osc_addr("active")
	var enabled_addr = osc_addr("enabled")
	var param_count_addr = osc_addr("param/count")
	var param_info_addr = osc_addr("param/info")
	var loading_state_addr = osc_addr("loading_state")
	var gui_closed_addr = osc_addr("gui/closed")

	AudioEngineOSC.listen(active_addr, _on_active_received)
	AudioEngineOSC.listen(enabled_addr, _on_enabled_received)
	AudioEngineOSC.listen(param_count_addr, _on_param_count_received)
	AudioEngineOSC.listen(param_info_addr, _on_param_info_received)
	AudioEngineOSC.listen(loading_state_addr, _on_loading_state_received)
	AudioEngineOSC.listen(gui_closed_addr, _on_gui_closed_received)

	# Use wildcard pattern to listen for ALL parameter changes for this device
	var param_pattern = osc_addr("param/*/value")
	AudioEngineOSC.listen(param_pattern, _on_parameter_value_received_wildcard)

	sync_slot_to_engine()
	for child in children:
		child.connect_to_engine()


## Disconnect from audio engine: stop listening.
func disconnect_from_engine() -> void:
	if not _is_connected:
		return
	_is_connected = false

	var active_addr = osc_addr("active")
	var enabled_addr = osc_addr("enabled")
	var param_count_addr = osc_addr("param/count")
	var param_info_addr = osc_addr("param/info")
	var param_pattern = osc_addr("param/*/value")
	var loading_state_addr = osc_addr("loading_state")
	var gui_closed_addr = osc_addr("gui/closed")

	AudioEngineOSC.unlisten(active_addr, _on_active_received)
	AudioEngineOSC.unlisten(enabled_addr, _on_enabled_received)
	AudioEngineOSC.unlisten(param_count_addr, _on_param_count_received)
	AudioEngineOSC.unlisten(param_info_addr, _on_param_info_received)
	AudioEngineOSC.unlisten(param_pattern, _on_parameter_value_received_wildcard)
	AudioEngineOSC.unlisten(loading_state_addr, _on_loading_state_received)
	AudioEngineOSC.unlisten(gui_closed_addr, _on_gui_closed_received)
	for child in children:
		child.disconnect_from_engine()


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
				logger.info("[%s] Loading complete" % device.name)


func _on_gui_closed_received(_values: Array) -> void:
	"""Handle GUI closed notification from engine."""
	logger.info("[%s] Plugin GUI closed by engine" % device.name)
	plugin_gui_closed.emit()


func _on_parameter_value_received_wildcard(values: Array, address: String) -> void:
	"""Handle parameter value changes via wildcard pattern.
	Parse param_id from the OSC address: /channel/X/device/Y/param/ID/value"""
	# Parse parameter ID from address: .../param/ID/value
	var parts = address.split("/")
	var param_idx := parts.find("param")
	if param_idx < 0 or param_idx + 1 >= parts.size():
		push_warning("[DeviceInstance] Invalid parameter address format: %s" % address)
		return
	var param_id = int(parts[param_idx + 1])
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
	parameters.clear()
	parameter_values.clear()
	
	logger.debug("[%s] Expecting %d parameters" % [device.name, count])


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
	if args.size() >= 6 and args[5] is String:
		param.group = args[5]
	parameters.append(param)
	
	parameter_values[param_id] = _value_for_advertised_param(param_id, param)
	
	logger.debug("[%s] Param %d: %s [%.2f - %.2f, default %.2f]" %
		[device.name, param_id, param_name, min_val, max_val, default_val])

	# Check if we've received all expected parameters
	if parameters.size() >= _expected_param_count and _expected_param_count > 0:
		logger.debug("[%s] All %d parameters loaded" % [device.name, _expected_param_count])
		_expected_param_count = 0  # Reset
		_push_restored_parameters_to_engine()
		parameters_updated.emit()


## Prefer a project-restored value over the engine default when a param list is advertised.
func _value_for_advertised_param(param_id: int, param: DeviceParameter) -> float:
	if param_id in _restored_parameter_values:
		return clamp(_restored_parameter_values[param_id], 0.0, 1.0)
	return param.value_to_normalized(param.default_value)


## After SFZ/plugin param advertisement, send restored values so the engine matches the project.
func _push_restored_parameters_to_engine() -> void:
	if _restored_parameter_values.is_empty():
		return
	sync_to_engine()
	_restored_parameter_values.clear()


## Sync this device instance's parameters to the audio engine (bulk sync)
## TODO: Implement this
func sync_to_engine() -> void:
	for param_id in parameter_values:
		var param = get_parameter(param_id)
		if param and not param.syncable:
			continue
		var normalized_value = parameter_values[param_id]
		if param and param.param_type == "bool":
			var idx: int = 1 if normalized_value >= 0.5 else 0
			AudioEngineOSC.send(osc_addr("param/%d" % param_id), [idx])
		elif param and param.param_type == "enum":
			var n: int = max(1, param.enum_values.size())
			var idx: int = int(round(normalized_value * float(n - 1)))
			AudioEngineOSC.send(osc_addr("param/%d" % param_id), [idx])
		else:
			AudioEngineOSC.send(osc_addr("param/%d" % param_id), [normalized_value])


## Sync a single parameter to the audio engine
func sync_parameter_to_engine(param_id: int) -> void:
	if param_id in parameter_values:
		var param = get_parameter(param_id)
		if param and not param.syncable:
			return
		var normalized_value = parameter_values[param_id]
		if param and param.param_type == "bool":
			var idx: int = 1 if normalized_value >= 0.5 else 0
			logger.debug("send BOOL param_id=", param_id, " idx=", idx)
			AudioEngineOSC.send(osc_addr("param/%d" % param_id), [idx])
		elif param and param.param_type == "enum":
			var n: int = max(1, param.enum_values.size())
			var idx: int = int(round(normalized_value * float(n - 1)))
			logger.debug("send ENUM param_id=", param_id, " idx=", idx, " n=", n, " normalized=", normalized_value)
			AudioEngineOSC.send(osc_addr("param/%d" % param_id), [idx])
		else:
			logger.debug("send FLOAT param_id=", param_id, " normalized=", normalized_value)
			AudioEngineOSC.send(osc_addr("param/%d" % param_id), [normalized_value])


## Load a file into this device (SFZ or audio sample).
func load_file(file_path: String) -> void:
	if not device.supports_file_loading:
		push_error("[DeviceInstance] Device %s does not support file loading" % device.name)
		return

	logger.info("Loading file into %s: %s" % [device.name, file_path])
	loaded_file_path = file_path
	if sample_waveform == null:
		sample_waveform = WaveformPyramid.new()
	else:
		sample_waveform.reset()
	var req_id := "device:%s:%d" % [id, Time.get_ticks_usec()]
	var channel := get_channel()
	var project := channel.get_project() if channel else null
	if project:
		project.track_device_request(self, req_id)
	else:
		logger.warn("load_file on %s before it is on a project channel; waveform won't be tracked" % name)
	AudioEngineOSC.send(osc_addr("load_file"), [file_path, req_id])


## Remember `file_path` for an instance that is not on a channel yet. Channel.add_device()
## loads it right after telling the engine to create the device (or on connect when offline),
## so callers never have to wait for the engine before loading.
func queue_file_load(file_path: String) -> void:
	if device == null or not device.supports_file_loading:
		push_error("[DeviceInstance] Device %s does not support file loading" % (device.name if device else "?"))
		return
	loaded_file_path = file_path


## Send Layer/Drum slot controls to the engine (no-op for other parents).
func sync_slot_to_engine() -> void:
	var parent := get_parent_device()
	if parent == null or parent.device == null:
		return
	if parent.device.device_id == "sonara.builtin.layer":
		AudioEngineOSC.send(parent.osc_addr("slot/%d/volume" % position), [slot_volume])
		AudioEngineOSC.send(parent.osc_addr("slot/%d/mute" % position), [1 if slot_mute else 0])
		AudioEngineOSC.send(parent.osc_addr("slot/%d/solo" % position), [1 if slot_solo else 0])
	elif parent.device.device_id == "sonara.builtin.drum_machine" and slot_note >= 0:
		AudioEngineOSC.send(parent.osc_addr("slot/%d/note" % position), [slot_note])


## Set this child's Layer slot volume (normalized 0–1, 0.5 = unity).
func set_slot_volume(normalized: float) -> void:
	slot_volume = clampf(normalized, 0.0, 1.0)
	sync_slot_to_engine()
	slot_changed.emit()


## Mute this Layer slot.
func set_slot_mute(muted: bool) -> void:
	slot_mute = muted
	sync_slot_to_engine()
	slot_changed.emit()


## Solo this Layer slot.
func set_slot_solo(soloed: bool) -> void:
	slot_solo = soloed
	sync_slot_to_engine()
	slot_changed.emit()


## Assign the MIDI note this Drum Machine child responds to.
func set_slot_note(note: int) -> void:
	slot_note = clampi(note, 0, 127)
	sync_slot_to_engine()
	slot_changed.emit()


## Next unused pad note from C1 upward (Drum Machine containers only).
func next_free_drum_note() -> int:
	var used := {}
	for child in children:
		if child.slot_note >= 0:
			used[child.slot_note] = true
	for n in range(36, 128):
		if not used.has(n):
			return n
	for n in range(0, 36):
		if not used.has(n):
			return n
	return 36


## ============================================================================
## SERIALIZATION
## ============================================================================

## Serialize to JSON
func to_json() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"device_id": device.id,
		"channel_id": channel_id,
		"position": position,
		"active": active,
		"enabled": enabled,
		"parameter_values": _parameter_values_to_json(),
		"loaded_file_path": loaded_file_path,
		"children": children.map(func(c): return c.to_json()),
		"slot_volume": slot_volume,
		"slot_mute": slot_mute,
		"slot_solo": slot_solo,
		"slot_note": slot_note,
		"return_channel_id": return_channel_id,
		"return_channel_ids": return_channel_ids.duplicate(),
	}


## JSON object keys must be strings; keep parameter IDs stable across save/load.
func _parameter_values_to_json() -> Dictionary:
	var out := {}
	for param_id in parameter_values:
		out[str(param_id)] = parameter_values[param_id]
	return out


## Deserialize from JSON
static func from_json(data: Dictionary) -> DeviceInstance:
	var device_id = data.get("device_id", "")
	var loaded_device = AssetService.get_device(device_id)
	
	if not loaded_device:
		logger.warn("Device not found (may need plugin scan): %s" % device_id)
		return null
	
	var chan_id = data.get("channel_id", 0)
	var pos = data.get("position", 0)
	var is_active = data.get("active", true)
	var is_enabled = data.get("enabled", true)
	
	var instance = DeviceInstance.new(loaded_device, chan_id, pos, is_active, is_enabled)
	instance.id = data.get("id", instance.id)  # Restore original ID
	instance.name = str(data.get("name", ""))
	
	# Restore parameter values (kept aside so SFZ/plugin advertisement does not wipe them)
	var param_values = data.get("parameter_values", {})
	for param_id_str in param_values.keys():
		var param_id = int(param_id_str) if param_id_str is String else param_id_str
		var value = float(param_values[param_id_str])
		instance.parameter_values[param_id] = value
		instance._restored_parameter_values[param_id] = value
	
	# Restore loaded file path (will be reloaded after engine connection)
	instance.loaded_file_path = data.get("loaded_file_path", "")
	instance.slot_volume = float(data.get("slot_volume", 0.5))
	instance.slot_mute = bool(data.get("slot_mute", false))
	instance.slot_solo = bool(data.get("slot_solo", false))
	instance.slot_note = int(data.get("slot_note", -1))
	instance.return_channel_id = int(data.get("return_channel_id", -1))
	var extra_ids = data.get("return_channel_ids", [])
	instance.return_channel_ids.assign(extra_ids)

	for child_data in data.get("children", []):
		if child_data is Dictionary:
			var child := DeviceInstance.from_json(child_data)
			if child:
				child.set_parent_device(instance)
				instance.children.append(child)

	return instance


## ============================================================================
## DISPLAY HELPERS
## ============================================================================

## Instance name if assigned, otherwise the device type name.
func get_display_name() -> String:
	if not name.is_empty():
		return name
	return device.name if device else "Device"


## Channel/device/child path for the assistant, e.g. `Kick/Chain/Delay 2`.
func address_path(project: Project = null) -> String:
	var ch := get_channel()
	if ch == null and project:
		ch = project.get_channel_by_id(channel_id)
	var parts: PackedStringArray = []
	if ch:
		parts.append(ch.name)
	var names: PackedStringArray = []
	var current: DeviceInstance = self
	while current:
		names.insert(0, current.get_display_name())
		current = current.get_parent_device()
	for n in names:
		parts.append(n)
	return "/".join(parts)
