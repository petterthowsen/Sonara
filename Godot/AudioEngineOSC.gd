# AudioEngineOSC.gd
# Low-level OSC communication layer with the Rust audio engine
# Provides simple send() and listen() interface for data classes to use

extends Node

# ============================================================================
# SIGNALS
# ============================================================================

signal engine_connected()
signal engine_disconnected()

# ============================================================================
# CONSTANTS
# ============================================================================

const ENGINE_SEND_PORT = 7000  # Rust listens here
const ENGINE_RECEIVE_PORT = 7001  # Godot listens here

# ============================================================================
# NODES
# ============================================================================

var osc_client: OSCClient
var osc_server: OSCServer

# ============================================================================
# STATE
# ============================================================================

var is_connected: bool = false

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

	The callback will be called with the OSC message arguments (values).
	Example: listen('/channel/1/peak', _on_peak_received)
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


# ============================================================================
# INTERNAL - OSC message routing
# ============================================================================

func _on_osc_message_received(address: String, values, _time) -> void:
	"""Route incoming OSC messages to registered listeners."""

	# Special handling for connection status messages
	if address == "/status/playing":
		if not is_connected:
			is_connected = true
			engine_connected.emit()
			print("[AudioEngineOSC] Engine connected!")

	# Route to registered listeners
	if listeners.has(address):
		for callback in listeners[address]:
			callback.call(values)

	# Debug logging for unhandled messages (at reduced frequency)
	elif randf() > 0.99:
		print("[AudioEngineOSC] Unhandled message: ", address, " = ", values)
