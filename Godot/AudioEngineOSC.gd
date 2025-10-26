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

# ============================================================================
# CONSTANTS
# ============================================================================

const ENGINE_SEND_PORT = 7000  # Rust listens here
const ENGINE_RECEIVE_PORT = 7001  # Godot listens here
const HEARTBEAT_TIMEOUT_SEC = 3.0  # Disconnect if no heartbeat for 3 seconds

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

	# Give the server a moment to start listening
	await get_tree().process_frame

	print("[AudioEngineOSC] Ready - listening on port %d, sending to port %d" % [ENGINE_RECEIVE_PORT, ENGINE_SEND_PORT])


func _process(_delta: float) -> void:
	"""Check for heartbeat timeout."""
	if _is_engine_connected:
		var time_since_heartbeat = (Time.get_ticks_msec() - _last_heartbeat_time) / 1000.0
		if time_since_heartbeat > HEARTBEAT_TIMEOUT_SEC:
			print("[AudioEngineOSC] Heartbeat timeout (%.1fs) - engine disconnected" % time_since_heartbeat)
			_is_engine_connected = false
			engine_disconnected.emit()


# ============================================================================
# PUBLIC API - Low-level send/listen interface
# ============================================================================

func send(address: String, args: Array = []) -> void:
	"""Send an OSC message to the audio engine."""
	if osc_client:
		print("sending ", address, " args: ", args)
		osc_client.send_message(address, args)
	else:
		push_warning("[AudioEngineOSC] OSC client not initialized")


func send_audio_data(address: String, audio_samples: PackedFloat32Array, sample_rate: int, channels: int) -> void:
	"""Send audio clip data as OSC message with proper binary encoding.

	Converts PackedFloat32Array to binary blob format for OSC transmission.
	"""
	if not osc_client:
		push_warning("[AudioEngineOSC] OSC client not initialized")
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

	print("[AudioEngineOSC] Sending audio data: %d samples, %d Hz, %d channels (blob size: %d bytes)" % [
		audio_samples.size(), sample_rate, channels, bytes.size()
	])

	osc_client.send_message(address, [bytes, sample_rate, channels])


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
		print("[AudioEngineOSC] Registered listener for ", address)


func unlisten(address: String, callback: Callable) -> void:
	"""Unregister a callback for an OSC address."""
	if listeners.has(address):
		listeners[address].erase(callback)
		if listeners[address].is_empty():
			listeners.erase(address)
		print("[AudioEngineOSC] Unregistered listener for ", address)


func reset_connection() -> void:
	"""Reset connection state (called when project disconnects)."""
	if _is_engine_connected:
		_is_engine_connected = false
		engine_disconnected.emit()
		print("[AudioEngineOSC] Connection reset")


# ============================================================================
# INTERNAL - OSC message routing
# ============================================================================

func _on_osc_message_received(address: String, values, _time) -> void:
	"""Route incoming OSC messages to registered listeners."""

	# Special handling for connection status messages
	if address == "/status/connected":
		if not _is_engine_connected and values is Array and values.size() > 0 and values[0] == 1:
			_is_engine_connected = true
			_last_heartbeat_time = Time.get_ticks_msec()
			engine_connected.emit()
			print("[AudioEngineOSC] Engine connected!")
	elif address == "/status/playing":
		if not _is_engine_connected:
			_is_engine_connected = true
			_last_heartbeat_time = Time.get_ticks_msec()
			engine_connected.emit()
			print("[AudioEngineOSC] Engine connected!")
	elif address == "/status/heartbeat":
		# Update last heartbeat time
		_last_heartbeat_time = Time.get_ticks_msec()
	
	# Special handling for log messages
	elif address == "/log":
		if values is Array and values.size() >= 2:
			var level: String = values[0]
			var message: String = values[1]
			engine_log_message.emit(level, message)
			# Also print to console for convenience
			if level == "error":
				push_error("[Engine] " + message)
			elif level == "warn":
				print("[Engine] warn: " + message)
			return  # Don't route to other listeners

	# Normalize values to always be an Array for consistent callback interface
	var args: Array
	if values is Array:
		args = values
	else:
		# Single value - wrap in array
		args = [values]

	# Route to registered listeners (exact match first, then wildcards)
	var routed = false
	
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
				print("[AudioEngineOSC] ⚠️  No listener for: " + address)
		elif randf() > 0.99:
			# Other unhandled messages
			print("[AudioEngineOSC] Unhandled message: ", address, " = ", args)


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
