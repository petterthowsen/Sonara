class_name Channel extends RefCounted

# Channel types
enum ChannelType {
	INSTRUMENT,  # MIDI instrument track
	AUDIO,       # Audio track
	BUS          # Bus/group channel (routing only)
}

# Pan modes (Cubase-style)
enum PanMode {
	STEREO_COMBINED,  # Single pan knob controls stereo balance (Cubase default)
	STEREO_DUAL,      # Separate L/R pan controls
	STEREO_BALANCE,   # Balance between L and R channels
	MONO              # Mono panner (single channel)
}

# ============================================================================
# SIGNALS
# ============================================================================

signal name_changed(name : String)
signal color_changed(color : Color)
signal volume_changed(value: float)
signal pan_changed(value: float)
signal pan_mode_changed(pan_mode: PanMode)
signal mute_changed(value: bool)
signal solo_changed(value: bool)
signal peak_updated(left: float, right: float, rms_left: float, rms_right: float)
signal route_changed(output_id: int)

# Send signals
signal send_added(target_channel_id: int, send_config: SendConfig)
signal send_removed(target_channel_id: int)
signal send_changed(target_channel_id: int, send_config: SendConfig)

# Device chain signals
signal device_added(device_instance: DeviceInstance, position: int)
signal device_removed(position: int, device_id: String)
signal device_moved(from_position: int, to_position: int)
signal device_parameter_changed(position: int, param_id: int, value: float)
signal device_parameters_updated(position: int)  # Emitted when plugin parameters are loaded

# ============================================================================
# PROPERTIES
# ============================================================================

# Unique ID (set in _init, immutable)
var id: int = -1

# Basic properties
var name: String = "Channel"
var color: Color = Color.WHITE
var order: int = 0  # Display order in mixer (lower = left, higher = right)

# Audio properties
var volume: float = 0.0  # dB (-60 to +12), initialized in _init() based on channel ID
var pan: float = 0.0     # -1.0 (L) to +1.0 (R) for STEREO_COMBINED/MONO
var pan_left: float = 0.0   # For STEREO_DUAL mode
var pan_right: float = 0.0  # For STEREO_DUAL mode
var pan_mode: PanMode = PanMode.STEREO_COMBINED

var mute: bool = false
var solo: bool = false
var phase_invert: bool = false

# Channel type and properties
var channel_type: ChannelType = ChannelType.INSTRUMENT
var device_output_id: int = 1000  # Hardware output device (1000+ reserved)

# Routing
var output_channel_id: int = 1  # Channel to route to (1 = master by default)
var send_channels: Array = []  # Array of SendConfig objects

# Device chain
var devices: Array[DeviceInstance] = []  # Ordered list of devices on this channel

# Metering (runtime state, not serialized)
var peak_left: float = 0.0   # Current peak level (linear 0.0-1.0+)
var peak_right: float = 0.0
var rms_left: float = 0.0    # RMS level
var rms_right: float = 0.0

# Connection state
var _is_connected: bool = false

# Track routing (tracks that route to this channel)
var routed_tracks: Array[Track] = []

# Helper properties
var is_bus : bool:
	get:
		return channel_type == ChannelType.BUS

var is_master : bool:
	get:
		return id == 1

# ============================================================================
# LIFECYCLE
# ============================================================================

func _init(channel_id: int = -1):
	"""Initialize channel with unique ID."""
	id = channel_id
	# Master channel (ID 1) defaults to 0 dB, others default to -6 dB for headroom
	if id == 1:
		volume = 0.0
	else:
		volume = -6.0


# ============================================================================
# AUDIO ENGINE SYNC
# ============================================================================

func connect_to_engine() -> void:
	"""Connect to audio engine: setup listeners and sync initial state."""
	if _is_connected:
		return

	# Listen for incoming peak meter updates
	AudioEngineOSC.listen("/channel/%d/peak" % id, _on_peak_received)

	# Sync current state to engine
	sync_to_engine()
	
	# Connect all device instances to engine
	for device_inst in devices:
		device_inst.connect_to_engine()

	_is_connected = true
	print("[Channel %d] Connected to audio engine" % id)


func disconnect_from_engine() -> void:
	"""Disconnect from audio engine."""
	if not _is_connected:
		return

	# Unlisten from OSC messages
	AudioEngineOSC.unlisten("/channel/%d/peak" % id, _on_peak_received)
	
	# Disconnect all device instances from engine
	for device_inst in devices:
		device_inst.disconnect_from_engine()
	
	# DeviceInstances handle their own parameter listeners now

	_is_connected = false
	print("[Channel %d] Disconnected from audio engine" % id)


func sync_to_engine() -> void:
	"""Sync current channel state to audio engine."""
	AudioEngineOSC.send("/channel/%d/create" % id, [name])
	AudioEngineOSC.send("/channel/%d/volume" % id, [volume])
	AudioEngineOSC.send("/channel/%d/pan" % id, [pan])
	AudioEngineOSC.send("/channel/%d/mute" % id, [1 if mute else 0])
	AudioEngineOSC.send("/channel/%d/solo" % id, [1 if solo else 0])

	# Master channel: routes to device output
	if is_master:
		AudioEngineOSC.send("/channel/%d/route" % id, [device_output_id])
	else:
		# Regular channels: route to output channel
		AudioEngineOSC.send("/channel/%d/route" % id, [output_channel_id])
	
	# Sync all sends to engine
	for send in send_channels:
		AudioEngineOSC.send("/channel/%d/send/%d/add" % [id, send.target_channel_id], [send.amount, 1 if send.pre_fader else 0])
		if send.muted:
			AudioEngineOSC.send("/channel/%d/send/%d/mute" % [id, send.target_channel_id], [1])
	
	# Sync all devices to engine (for project loading)
	for device_inst in devices:
		# Send device ID, position, active, enabled, type, and file path
		var active = 1 if device_inst.active else 0
		var enabled = 1 if device_inst.enabled else 0
		var device_type = _get_device_type_string(device_inst.device.device_type)
		AudioEngineOSC.send("/channel/%d/add_device" % id, [
			device_inst.device.device_id, 
			device_inst.position,
			active,
			enabled,
			device_type,  # "builtin", "clap", "lv2", "vst3"
			device_inst.device.plugin_path  # File path (empty for built-ins)
		])
		device_inst.sync_to_engine()
		
		# Connect to device's parameters_updated signal
		device_inst.parameters_updated.connect(_on_device_parameters_updated.bind(device_inst.position))
		
		# For plugin devices (CLAP/LV2/VST3), query parameters from engine
		if device_inst.device.device_type != Device.DeviceType.BuiltIn:
			AudioEngineOSC.send("/plugin/get_parameters", [id, device_inst.position])
			print("[Channel %d] Querying parameters for device at position %d" % [id, device_inst.position])


# ============================================================================
# PROPERTY SETTERS (with audio engine sync where appropriate)
# ============================================================================
func set_name(new_name : String):
	name = new_name
	name_changed.emit(name)
	
	# Update all routed tracks that sync name from channel
	for track in routed_tracks:
		if track.name_by_channel:
			track._name = new_name
			track.name_changed.emit(new_name)


func set_color(new_color : Color):
	color = new_color
	color_changed.emit(color)
	
	# Update all routed tracks that sync color from channel
	for track in routed_tracks:
		if track.color_by_channel:
			track._color = new_color
			track.color_changed.emit(new_color)


func set_volume(value: float) -> void:
	"""Set volume and sync to audio engine."""
	volume = clamp(value, -60.0, 12.0)
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/volume" % id, [volume])
	volume_changed.emit(volume)


func set_pan_mode(mode : PanMode) -> void:
	pan_mode = mode

	# When switching to STEREO_DUAL mode, initialize pan_left and pan_right to default values
	if mode == PanMode.STEREO_DUAL:
		pan_left = -1.0
		pan_right = 1.0

	if _is_connected:
		AudioEngineOSC.send("/channel/%d/pan_mode" % id, [pan_mode])
		# Also sync pan values when switching modes
		if mode == PanMode.STEREO_DUAL:
			AudioEngineOSC.send("/channel/%d/pan" % id, [pan_left, pan_right])
		else:
			AudioEngineOSC.send("/channel/%d/pan" % id, [pan])

	pan_mode_changed.emit(pan_mode)
	# Emit pan_changed to update UI with the new pan values
	pan_changed.emit(pan_left, pan_right)


func set_pan(pan_l: float, pan_r : float = 0.0) -> void:
	"""Set pan and sync to audio engine."""
	if pan_mode == PanMode.STEREO_COMBINED:
		pan = clamp(pan_l, -1.0, 1.0)
		pan_left = pan
		if _is_connected:
			print("sending channel pan to ", pan)
			AudioEngineOSC.send("/channel/%d/pan" % id, [pan])
	elif pan_mode == PanMode.STEREO_DUAL:
		pan_left = clamp(pan_l, -1.0, 1.0)
		pan_right = clamp(pan_r, -1.0, 1.0)
		if _is_connected:
			AudioEngineOSC.send("/channel/%d/pan" % id, [pan_left, pan_right])
	
	pan_changed.emit(pan_left, pan_right)


func set_mute(value: bool) -> void:
	"""Set mute and sync to audio engine."""
	mute = value
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/mute" % id, [1 if mute else 0])
	mute_changed.emit(mute)


func set_solo(value: bool) -> void:
	"""Set solo and sync to audio engine."""
	solo = value
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/solo" % id, [1 if solo else 0])
	solo_changed.emit(solo)


func set_route(output_id: int) -> void:
	"""Set output routing and sync to audio engine.

	Routing rules:
	- INSTRUMENT/AUDIO channels: route to Master (ID 1) or BUS channels
	- BUS channels: route to Master (ID 1) or other BUS channels

	This prevents invalid hierarchies like INSTRUMENT -> INSTRUMENT.
	The UI filters available options; this is a safety check for edge cases.
	"""
	# Validate routing: reject self-routing to prevent feedback loops
	if output_id == id:
		print("[Channel %d] Cannot route to self, ignoring route to %d" % [id, output_id])
		return

	# Allow all other routing combinations (UI already filters options)
	# - Master always accepts incoming routes (ID 1)
	# - BUS and INSTRUMENT/AUDIO channels only receive filtered options

	output_channel_id = output_id
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/route" % id, [output_channel_id])
	route_changed.emit(output_channel_id)


# ============================================================================
# SEND MANAGEMENT
# ============================================================================

func add_send(target_channel_id: int, amount_db: float = -12.0, pre_fader: bool = false) -> void:
	"""Add a send to a BUS channel and sync to audio engine."""
	# Check if send already exists
	for send in send_channels:
		if send.target_channel_id == target_channel_id:
			print("[Channel %d] Send to channel %d already exists" % [id, target_channel_id])
			return
	
	# Validate target is not self
	if target_channel_id == id:
		print("[Channel %d] Cannot send to self" % id)
		return
	
	# Create send config
	var send_config = SendConfig.new()
	send_config.target_channel_id = target_channel_id
	send_config.amount = amount_db
	send_config.pre_fader = pre_fader
	send_config.muted = false
	
	# Add to local array
	send_channels.append(send_config)
	
	# Sync to engine
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/send/%d/add" % [id, target_channel_id], [amount_db, 1 if pre_fader else 0])
	
	send_added.emit(target_channel_id, send_config)
	print("[Channel %d] Send added to channel %d (%.1f dB, %s)" % [id, target_channel_id, amount_db, "pre-fader" if pre_fader else "post-fader"])


func remove_send(target_channel_id: int) -> void:
	"""Remove a send and sync to audio engine."""
	var found = false
	for i in range(send_channels.size()):
		if send_channels[i].target_channel_id == target_channel_id:
			send_channels.remove_at(i)
			found = true
			break
	
	if not found:
		print("[Channel %d] Send to channel %d not found" % [id, target_channel_id])
		return
	
	# Sync to engine
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/send/%d/remove" % [id, target_channel_id])
	
	send_removed.emit(target_channel_id)
	print("[Channel %d] Send removed to channel %d" % [id, target_channel_id])


func set_send_amount(target_channel_id: int, amount_db: float) -> void:
	"""Set send level and sync to audio engine."""
	var send_config = get_send(target_channel_id)
	if not send_config:
		print("[Channel %d] Send to channel %d not found" % [id, target_channel_id])
		return
	
	send_config.amount = clamp(amount_db, -60.0, 12.0)
	
	# Sync to engine
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/send/%d/amount" % [id, target_channel_id], [send_config.amount])
	
	send_changed.emit(target_channel_id, send_config)


func set_send_pre_fader(target_channel_id: int, pre_fader: bool) -> void:
	"""Set send pre/post fader and sync to audio engine."""
	var send_config = get_send(target_channel_id)
	if not send_config:
		print("[Channel %d] Send to channel %d not found" % [id, target_channel_id])
		return
	
	send_config.pre_fader = pre_fader
	
	# Sync to engine
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/send/%d/pre_fader" % [id, target_channel_id], [1 if pre_fader else 0])
	
	send_changed.emit(target_channel_id, send_config)
	print("[Channel %d] Send to channel %d set to %s" % [id, target_channel_id, "pre-fader" if pre_fader else "post-fader"])


func set_send_mute(target_channel_id: int, muted: bool) -> void:
	"""Set send mute state and sync to audio engine."""
	var send_config = get_send(target_channel_id)
	if not send_config:
		print("[Channel %d] Send to channel %d not found" % [id, target_channel_id])
		return
	
	send_config.muted = muted
	
	# Sync to engine
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/send/%d/mute" % [id, target_channel_id], [1 if muted else 0])
	
	send_changed.emit(target_channel_id, send_config)
	print("[Channel %d] Send to channel %d %s" % [id, target_channel_id, "muted" if muted else "unmuted"])


func get_send(target_channel_id: int) -> SendConfig:
	"""Get send configuration for a target channel."""
	for send in send_channels:
		if send.target_channel_id == target_channel_id:
			return send
	return null


# ============================================================================
# OSC CALLBACKS
# ============================================================================

func _on_peak_received(values) -> void:
	"""Handle incoming peak and RMS meter data from audio engine."""
	if values is Array and values.size() >= 2:
		peak_left = values[0] as float
		peak_right = values[1] as float
		rms_left = values[2] as float
		rms_right = values[3] as float
		peak_updated.emit(peak_left, peak_right, rms_left, rms_right)


# ============================================================================
# UTILITY METHODS
# ============================================================================

# Get effective pan values based on mode
func get_pan_coefficients() -> Dictionary:
	match pan_mode:
		PanMode.STEREO_COMBINED:
			# Constant power panning
			var angle = (pan + 1.0) * 0.5 * PI * 0.5  # Map -1..1 to 0..PI/2
			return {
				"left_to_left": cos(angle),
				"right_to_right": sin(angle),
				"left_to_right": 0.0,
				"right_to_left": 0.0
			}
		PanMode.STEREO_DUAL:
			var angle_l = (pan_left + 1.0) * 0.5 * PI * 0.5
			var angle_r = (pan_right + 1.0) * 0.5 * PI * 0.5
			return {
				"left_to_left": cos(angle_l),
				"right_to_right": sin(angle_r),
				"left_to_right": sin(angle_l),
				"right_to_left": cos(angle_r)
			}
		PanMode.STEREO_BALANCE:
			# Simple balance: pan < 0 reduces right, pan > 0 reduces left
			var left_gain = 1.0 if pan <= 0.0 else (1.0 - pan)
			var right_gain = 1.0 if pan >= 0.0 else (1.0 + pan)
			return {
				"left_to_left": left_gain,
				"right_to_right": right_gain,
				"left_to_right": 0.0,
				"right_to_left": 0.0
			}
		PanMode.MONO:
			# Mono to stereo panning
			var angle = (pan + 1.0) * 0.5 * PI * 0.5
			return {
				"left_to_left": cos(angle),
				"right_to_right": sin(angle),
				"left_to_right": sin(angle),
				"right_to_left": cos(angle)
			}

	# Fallback
	return {"left_to_left": 1.0, "right_to_right": 1.0, "left_to_right": 0.0, "right_to_left": 0.0}


# Convert dB to linear gain
func get_linear_gain() -> float:
	return Sonara.db_to_lin(volume)


# ============================================================================
# TRACK ROUTING MANAGEMENT
# ============================================================================

func register_track(track: Track) -> void:
	"""Register a track that routes to this channel."""
	if track not in routed_tracks:
		routed_tracks.append(track)
		print("[Channel %d] Track '%s' registered (routes to this channel)" % [id, track.name])


func unregister_track(track: Track) -> void:
	"""Unregister a track that no longer routes to this channel."""
	var idx = routed_tracks.find(track)
	if idx >= 0:
		routed_tracks.remove_at(idx)
		print("[Channel %d] Track '%s' unregistered" % [id, track.name])


## Convert Device.DeviceType enum to string for OSC
func _get_device_type_string(device_type: Device.DeviceType) -> String:
	match device_type:
		Device.DeviceType.BuiltIn:
			return "builtin"
		Device.DeviceType.CLAP:
			return "clap"
		Device.DeviceType.LV2:
			return "lv2"
		_:
			return "builtin"


# ============================================================================
# DEVICE CHAIN MANAGEMENT
# ============================================================================

func add_device(device_instance: DeviceInstance, position: int = -1) -> void:
	"""Add a device to the channel at the specified position.

	Args:
		device_instance: The DeviceInstance to add
		position: Position in chain (0 = first, -1 = append at end)
	"""
	if position < 0 or position >= devices.size():
		devices.append(device_instance)
		position = devices.size() - 1
	else:
		devices.insert(position, device_instance)

	# Update position indices for all devices after this one
	for i in range(position, devices.size()):
		devices[i].position = i

	# Sync to engine
	if _is_connected:
		# Send device ID, position, active, enabled, type, and file path
		var active = 1 if device_instance.active else 0
		var enabled = 1 if device_instance.enabled else 0
		var device_type = _get_device_type_string(device_instance.device.device_type)
		AudioEngineOSC.send("/channel/%d/add_device" % id, [
			device_instance.device.device_id, 
			position,
			active,
			enabled,
			device_type,  # "builtin", "clap", "lv2", "vst3"
			device_instance.device.plugin_path  # File path (empty for built-ins)
		])
		# Also sync the device's parameters
		device_instance.sync_to_engine()
		
		# Connect to device's parameters_updated signal
		device_instance.parameters_updated.connect(_on_device_parameters_updated.bind(position))
		
		# For plugin devices (CLAP/LV2/VST3), query parameters from engine
		if device_instance.device.device_type != Device.DeviceType.BuiltIn:
			AudioEngineOSC.send("/plugin/get_parameters", [id, position])
			print("[Channel %d] Querying parameters for device at position %d" % [id, position])

	# Connect to device parameter changes
	device_instance.parameter_changed.connect(_on_device_parameter_changed.bindv([position]))
	
	# Connect device instance to engine (for state sync)
	if _is_connected:
		device_instance.connect_to_engine()

	device_added.emit(device_instance, position)
	print("[Channel %d] Device added at position %d: %s" % [id, position, device_instance.device.name])


func remove_device(position: int) -> void:
	"""Remove a device from the channel.

	Args:
		position: Position in device chain to remove
	"""
	if position < 0 or position >= devices.size():
		print("[Channel %d] Invalid device position: %d" % [id, position])
		return

	var removed_device = devices[position]
	var device_id = removed_device.device.device_id

	# Disconnect device instance from engine
	if _is_connected:
		removed_device.disconnect_from_engine()

	# Disconnect from device signals
	removed_device.parameter_changed.disconnect(_on_device_parameter_changed)

	# Remove from array
	devices.remove_at(position)

	# Update position indices for all devices after this one
	for i in range(position, devices.size()):
		devices[i].position = i

	# Sync to engine
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/remove_device" % id, [position])

	device_removed.emit(position, device_id)
	print("[Channel %d] Device removed from position %d: %s" % [id, position, device_id])


func move_device(from_position: int, to_position: int) -> void:
	## Move a device from one position to another in the chain.
	##
	## Args:
	##   from_position: Current position in device chain (0-based)
	##   to_position: Target position in device chain (0-based)
	if from_position < 0 or from_position >= devices.size():
		print("[Channel %d] Invalid from_position: %d" % [id, from_position])
		return

	if to_position < 0 or to_position >= devices.size():
		print("[Channel %d] Invalid to_position: %d" % [id, to_position])
		return

	if from_position == to_position:
		print("[Channel %d] Device already at position %d, no move needed" % [id, from_position])
		return

	# Extract device from old position
	var device_instance = devices[from_position]
	devices.remove_at(from_position)

	# Insert at new position
	devices.insert(to_position, device_instance)

	# Update position indices for affected devices
	var min_pos = min(from_position, to_position)
	var max_pos = max(from_position, to_position)
	for i in range(min_pos, max_pos + 1):
		devices[i].position = i

	# Sync to engine
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/move_device" % id, [from_position, to_position])

	device_moved.emit(from_position, to_position)
	print("[Channel %d] Device moved from position %d to position %d: %s" % [id, from_position, to_position, device_instance.device.name])


func get_device(position: int) -> DeviceInstance:
	"""Get device at specified position, or null if invalid."""
	if position >= 0 and position < devices.size():
		return devices[position]
	return null


func get_device_count() -> int:
	"""Get number of devices on this channel."""
	return devices.size()


# ============================================================================
# PRIVATE CALLBACKS
# ============================================================================

func _on_device_parameter_changed(param_id: int, value: float, position: int) -> void:
	"""Handle parameter change from a device instance.
	
	NOTE: We do NOT send to engine here - DeviceInstance.set_parameter_normalized() 
	already handles sending. This callback only relays the signal for UI notifications.
	Sending here would create a feedback loop with engine echoes.
	"""
	# Relay signal for UI notifications (other UI components may listen to Channel's signal)
	device_parameter_changed.emit(position, param_id, value)


# ============================================================================
# SERIALIZATION
# ============================================================================

# Serialize to JSON
func to_json() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"color": color.to_html(),
		"order": order,
		"channel_type": ChannelType.keys()[channel_type],
		"device_output_id": device_output_id,
		"volume": volume,
		"pan": pan,
		"pan_left": pan_left,
		"pan_right": pan_right,
		"pan_mode": PanMode.keys()[pan_mode],
		"mute": mute,
		"solo": solo,
		"phase_invert": phase_invert,
		"output_channel_id": output_channel_id,
		"send_channels": send_channels.map(func(s): return s.to_json()) if not send_channels.is_empty() else [],
		"devices": devices.map(func(d): return d.to_json()) if not devices.is_empty() else []
	}


# Deserialize from JSON
static func from_json(data: Dictionary) -> Channel:
	var channel_id = data.get("id", -1)
	var channel = Channel.new(channel_id)

	channel.name = data.get("name", "Channel")
	channel.color = Color.from_string(data.get("color", "#FFFFFF"), Color.WHITE)
	channel.order = data.get("order", 0)

	# Parse channel type
	var channel_type_str = data.get("channel_type", "INSTRUMENT")
	channel.channel_type = ChannelType.get(channel_type_str) if ChannelType.has(channel_type_str) else ChannelType.INSTRUMENT

	channel.device_output_id = data.get("device_output_id", 1000)
	channel.volume = data.get("volume", 0.0)
	channel.pan = data.get("pan", 0.0)
	channel.pan_left = data.get("pan_left", 0.0)
	channel.pan_right = data.get("pan_right", 0.0)

	# Parse pan mode
	var pan_mode_str = data.get("pan_mode", "STEREO_COMBINED")
	channel.pan_mode = PanMode.get(pan_mode_str) if PanMode.has(pan_mode_str) else PanMode.STEREO_COMBINED

	channel.mute = data.get("mute", false)
	channel.solo = data.get("solo", false)
	channel.phase_invert = data.get("phase_invert", false)
	channel.output_channel_id = data.get("output_channel_id", 1)

	# Load send_channels
	for send_data in data.get("send_channels", []):
		if send_data is Dictionary:
			var send_config = SendConfig.from_json(send_data)
			channel.send_channels.append(send_config)
	
	# Load devices (do NOT use add_device - that would sync to engine prematurely)
	# Devices will be synced to engine when channel.connect_to_engine() is called
	for device_data in data.get("devices", []):
		if device_data is Dictionary:
			var device_instance = DeviceInstance.from_json(device_data)
			if device_instance:
				var pos = device_instance.position
				channel.devices.append(device_instance)
				
				# Connect to device parameter changes (same as add_device does)
				device_instance.parameter_changed.connect(channel._on_device_parameter_changed.bindv([pos]))
			else:
				# Device not found - skip it but log
				var device_id = device_data.get("device_id", "unknown")
				print("[Channel] Skipping missing device: %s (run Edit > Scan Plugins)" % device_id)

	return channel


# ============================================================================
# DEVICE PARAMETER MANAGEMENT
# ============================================================================

## Handle when a device's parameters are updated (forwarded from DeviceInstance)
func _on_device_parameters_updated(device_pos: int) -> void:
	"""Called when a device's parameter list changes (e.g., SFZ file loaded)."""
	print("[Channel %d] Device %d parameters updated" % [id, device_pos])
	device_parameters_updated.emit(device_pos)
