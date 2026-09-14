# AudioEngineOSC.gd
# Low-level OSC communication layer with the Rust audio engine
# Provides simple send() and listen() interface for data classes to use

extends Node

# ============================================================================
# SIGNALS
# ============================================================================

signal engine_connected()
signal engine_disconnected()
signal engine_log_message(level: String, message: String)  # Emitted for warn/error logs from engine

# Device data subscriptions (`osc_path` is `/channel/{id}/device/{n}` or nested `/child/{n}`)
signal device_data_received(osc_path: String, data_type: String, data: PackedByteArray)
signal device_spectrum_received(osc_path: String, spectrum: PackedFloat32Array)

# ============================================================================
# CONSTANTS
# ============================================================================

const ENGINE_SEND_PORT = 7000  # Rust listens here
const ENGINE_RECEIVE_PORT = 7001  # Godot listens here
const HEARTBEAT_TIMEOUT_SEC = 3.0  # Disconnect if no heartbeat for 3 seconds

var logger = Log.make("OSC")

# ============================================================================
# NODES
# ============================================================================

var osc_client: OSCClient
var osc_server: OSCServer

# ============================================================================
# STATE
# ============================================================================

var _is_engine_connected: bool = false
var _last_heartbeat_time: float = 0.0  # Time.get_ticks_msec() of last heartbeat
var _is_ready: bool = false  # Whether OSC server/client are fully initialized
## Messages sent before the UDP client is bound; flushed from `_ready()`.
var _pending_sends: Array[Dictionary] = []

# OSC message listeners: Dictionary[String, Array[Callable]]
# Maps OSC address pattern to array of callbacks
var listeners: Dictionary = {}

# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready() -> void:
	# Create OSC client (sends to Rust)
	osc_client = OSCClient.new()
	osc_client.ip_address = "127.0.0.1"
	osc_client.port = ENGINE_SEND_PORT
	add_child(osc_client)

	# Create OSC server (receives from Rust)
	osc_server = OSCServer.new()
	osc_server.port = ENGINE_RECEIVE_PORT
	osc_server.message_received.connect(_on_osc_message_received)
	add_child(osc_server)

	# Wait for OSC server to bind socket and start polling thread
	# Frame 1: add_child() schedules _ready() on OSCServer
	# Frame 2: OSCServer._ready() binds UDP socket and starts listening
	await get_tree().process_frame
	await get_tree().process_frame

	_is_ready = true
	logger.info("Ready - listening on port %d, sending to port %d" % [ENGINE_RECEIVE_PORT, ENGINE_SEND_PORT])
	_flush_pending_sends()


func _process(_delta: float) -> void:
	"""Check for heartbeat timeout."""
	if _is_engine_connected:
		var time_since_heartbeat = (Time.get_ticks_msec() - _last_heartbeat_time) / 1000.0
		if time_since_heartbeat > HEARTBEAT_TIMEOUT_SEC:
			logger.warn("Heartbeat timeout (%.1fs) - engine disconnected" % time_since_heartbeat)
			_is_engine_connected = false
			engine_disconnected.emit()


# ============================================================================
# PUBLIC API - Low-level send/listen interface
# ============================================================================

## Send an OSC message to the audio engine, queueing until sockets are bound.
func send(address: String, args: Array = []) -> void:
	if not _is_ready:
		_pending_sends.append({"address": address, "args": args})
		logger.debug("Queued send until OSC ready: %s" % address)
		return
	if osc_client:
		logger.debug("sending ", address, " args: ", args)
		osc_client.send_message(address, args)
	else:
		logger.warn("OSC client not initialized")


## Deliver messages that arrived before the OSC client finished binding.
func _flush_pending_sends() -> void:
	var queued := _pending_sends.duplicate()
	_pending_sends.clear()
	for item in queued:
		send(item["address"], item["args"])


func send_audio_data(address: String, audio_samples: PackedFloat32Array, sample_rate: int, channels: int) -> void:
	"""Send audio clip data as OSC message with proper binary encoding.

	Converts PackedFloat32Array to binary blob format for OSC transmission.
	"""
	if not osc_client:
		logger.warn("OSC client not initialized")
		return

	# Convert float samples to bytes (little-endian)
	var bytes = PackedByteArray()
	for sample in audio_samples:
		# Use var_to_bytes which handles the conversion properly
		# It returns the raw bytes of the float value
		var float_bytes = var_to_bytes(sample)
		# var_to_bytes returns: [type_byte (4 bytes), data...]
		# Skip the first 4 bytes and take the next 4 which are the float
		if float_bytes.size() >= 8:
			bytes.append_array(float_bytes.slice(4, 8))

	logger.info("Sending audio data: %d samples, %d Hz, %d channels (blob size: %d bytes)" % [
		audio_samples.size(), sample_rate, channels, bytes.size()
	])

	osc_client.send_message(address, [bytes, sample_rate, channels])


## Subscribe to device visualization data (spectrum, oscilloscope, etc.).
## `osc_path` is `DeviceInstance.osc_path()`, e.g. `/channel/2/device/0` or `/channel/2/device/0/child/1`.
func subscribe_device_data(osc_path: String, data_type: String) -> void:
	send("%s/data/subscribe" % osc_path, [data_type])


## Unsubscribe from device visualization data.
func unsubscribe_device_data(osc_path: String, data_type: String) -> void:
	send("%s/data/unsubscribe" % osc_path, [data_type])


func listen(address: String, callback: Callable) -> void:
	"""Register a callback for incoming OSC messages matching the address.

	The callback will be called with the OSC message arguments as an Array.
	Example: listen('/channel/1/peak', func(args: Array): print(args[0], args[1]))
	
	Note: Callbacks always receive an Array, even for single-value messages.
	"""
	if not listeners.has(address):
		listeners[address] = []

	if not listeners[address].has(callback):
		listeners[address].append(callback)
		logger.info("Registered listener for ", address)


func unlisten(address: String, callback: Callable) -> void:
	"""Unregister a callback for an OSC address."""
	if listeners.has(address):
		listeners[address].erase(callback)
		if listeners[address].is_empty():
			listeners.erase(address)
		logger.info("Unregistered listener for ", address)


func reset_connection() -> void:
	"""Reset connection state (called when project disconnects)."""
	if _is_engine_connected:
		_is_engine_connected = false
		engine_disconnected.emit()
		logger.info("Connection reset")


# ============================================================================
# INTERNAL - OSC message routing
# ============================================================================

func _on_osc_message_received(address: String, values, _time) -> void:
	"""Route incoming OSC messages to registered listeners."""

	# Track if message was handled
	var routed = false

	# Special handling for connection status messages.
	# Always emit on /status/connected so a new engine process can force a project resync
	# even if heartbeats never timed out (restart is often faster than HEARTBEAT_TIMEOUT_SEC).
	if address == "/status/connected":
		var connection_confirmed = false
		if values is Array and values.size() > 0:
			connection_confirmed = (values[0] == 1)
		elif values == 1:
			connection_confirmed = true

		if connection_confirmed:
			_is_engine_connected = true
			_last_heartbeat_time = Time.get_ticks_msec()
			engine_connected.emit()
			logger.info("Engine connected!")
		routed = true
	elif address == "/status/playing":
		if not _is_engine_connected:
			_is_engine_connected = true
			_last_heartbeat_time = Time.get_ticks_msec()
			engine_connected.emit()
			logger.info("Engine connected (via /status/playing)")
		routed = true
	elif address == "/status/heartbeat":
		# Update last heartbeat time
		_last_heartbeat_time = Time.get_ticks_msec()
		routed = true
	
	# Special handling for device data messages (top-level or nested child paths)
	elif address.begins_with("/channel/") and address.ends_with("/data"):
		var regex = RegEx.new()
		regex.compile("^(/channel/\\d+/device/\\d+(?:/child/\\d+)*)/data$")
		var result = regex.search(address)
		if result and values is Array and values.size() >= 2:
			var osc_path: String = result.get_string(1)
			var data_type: String = values[0]
			var blob: PackedByteArray = values[1]
			device_data_received.emit(osc_path, data_type, blob)
			if data_type == "spectrum":
				var spectrum = _decode_f32_array(blob)
				device_spectrum_received.emit(osc_path, spectrum)
		
		routed = true
	
	# Special handling for log messages
	elif address == "/log":
		if values is Array and values.size() >= 2:
			var level: String = values[0]
			var message: String = values[1]
			engine_log_message.emit(level, message)
			# Also log to console for convenience
			if level == "error":
				logger.error("[Engine] ", message)
			elif level == "warn":
				logger.warn("[Engine] ", message)
		return  # Don't route to other listeners

	# Normalize values to always be an Array for consistent callback interface
	var args: Array
	if values is Array:
		args = values
	else:
		# Single value - wrap in array
		args = [values]

	#if not address.contains("/peak") and not address.contains("/status") and not address.contains("/log"):
	#	logger.info("received OSC message: ", address, " args=", args)

	if address.begins_with("/audiofile"):
		logger.info("recv ", address, " args=", args)

	# Route to registered listeners (exact match first, then wildcards)
	# Try exact match
	if listeners.has(address):
		for callback in listeners[address]:
			callback.call(args)
		routed = true
	
	# Try wildcard patterns
	for pattern in listeners.keys():
		if pattern.contains("*") and _matches_wildcard(address, pattern):
			for callback in listeners[pattern]:
				callback.call(args, address)  # Pass address so callback can parse it
			routed = true
	
	# Debug logging for unrouted messages
	if not routed:
		if address.contains("/param/") and address.ends_with("/value"):
			# Parameter change with no listener
			if randf() < 0.05:  # Only log 5% to reduce spam
				logger.warn("⚠️  No listener for: " + address)
		else:
			# Other unhandled messages (reduced frequency to avoid spam)
			if randf() > 0.95:
				logger.warn("Unhandled message: ", address, " = ", args)


## Check if an address matches a wildcard pattern
## Pattern format: "/channel/2/device/1/param/*/value" matches "/channel/2/device/1/param/5/value"
func _matches_wildcard(address: String, pattern: String) -> bool:
	# Split both into segments
	var addr_parts = address.split("/")
	var pattern_parts = pattern.split("/")
	
	# Must have same number of segments
	if addr_parts.size() != pattern_parts.size():
		return false
	
	# Check each segment
	for i in range(addr_parts.size()):
		if pattern_parts[i] == "*":
			continue  # Wildcard matches anything
		if addr_parts[i] != pattern_parts[i]:
			return false
	
	return true


## Decode PackedByteArray containing f32 values to PackedFloat32Array
func _decode_f32_array(blob: PackedByteArray) -> PackedFloat32Array:
	# OSC blob encoding: 4-byte big-endian length, followed by payload, padded to 4 bytes
	if blob.size() < 4:
		return PackedFloat32Array()

	# Parse big-endian length
	var length := (int(blob[0]) << 24) | (int(blob[1]) << 16) | (int(blob[2]) << 8) | int(blob[3])
	var end_index := 4 + length
	if end_index > blob.size():
		# Corrupt blob; bail out safely
		return PackedFloat32Array()

	var payload := blob.slice(4, end_index)
	var float_count := payload.size() / 4  # Each f32 is 4 bytes
	var result := PackedFloat32Array()
	result.resize(float_count)

	for i in range(float_count):
		var offset := i * 4
		# Payload floats are little-endian (engine serialized native LE inside blob)
		var bytes := payload.slice(offset, offset + 4)
		result[i] = bytes.decode_float(0)

	return result
