class_name Project extends RefCounted

# ============================================================================
# ENUMS
# ============================================================================

enum ConnectionState {
	DISCONNECTED,
	CONNECTING,
	CONNECTED
}

# ============================================================================
# SIGNALS
# ============================================================================

signal track_added(track: Track)
signal track_removed(track: Track)
signal channel_added(channel: Channel)
signal channel_removed(channel: Channel)
signal clip_added(clip: Clip)
signal clip_removed(clip_id: String)
signal start_position_changed(ticks: int)
signal connection_state_changed(state: ConnectionState)
## Fired once after a batched parent/order change so TrackList and Timeline can rebuild together.
signal tracks_layout_changed

# ============================================================================
# PROPERTIES
# ============================================================================

# Time and tempo
var tempo: float = 120.0
var time_numerator: int = 4
var time_denominator: int = 4
var ppq: int = 960  # Pulses per quarter note
var sample_rate: int = 48000
var start_position_ticks: int = 0  # Playback start position

# Project data
var channels: Array[Channel] = []
var tracks: Array[Track] = []
var clips: Dictionary[String, Clip] = {}  # String (clip_id) → Clip (global clip pool)

# Async clip load tracking
var _clip_request_lookup: Dictionary = {}  # clip_id -> req_id
var _request_clip_lookup: Dictionary = {}  # req_id -> clip_id
var _request_device_lookup: Dictionary = {}  # req_id -> DeviceInstance
var _osc_listener_registry: Array = []
var _pending_waveform_retries: Dictionary = {}

# Unique ID management
# ID Allocation Scheme:
# - 0: Null/no output (reserved, channels routing to 0 won't output anywhere)
# - 1: Master channel (created in _init, reserved, routes to ID 1000)
# - 2-999: User channels (mixer channels for tracks, route to master by default)
# - 1000+: Hardware output devices (enumerated by audio engine on startup)
#   - 1000: Default output device (the one currently running the audio stream)
#   - 1001+: Additional output devices (future support for multi-device routing)
var next_channel_id: int = 2  # Counter for assigning unique channel IDs (starts after master)
var next_track_id: int = 0    # Counter for assigning unique track IDs
var next_clip_id: int = 1     # Counter for assigning unique clip IDs
var next_note_id: int = 1     # Counter for assigning unique MIDI note IDs

# Project metadata
var project_name: String = "Untitled"
var created_date: int = 0  # Unix timestamp
var modified_date: int = 0

# Connection state
var _connection_state: ConnectionState = ConnectionState.DISCONNECTED

## Depth of nested place_track / apply_track_layout batches (UI skips per-track rebuilds).
var _track_layout_batch: int = 0


## Get current connection state
func get_connection_state() -> ConnectionState:
	return _connection_state


## Check if project is connected to engine
func is_connected_to_engine() -> bool:
	return _connection_state == ConnectionState.CONNECTED

# ============================================================================
# LIFECYCLE
# ============================================================================

func _init():
	"""Initialize project with master channel (always ID 1)."""
	var master = Channel.new(1)  # Master is always ID 1
	master.name = "Master"
	master.output_channel_id = 1000  # Master routes to default output device (ID 1000)
	master.order = 1000  # High order value to appear on the right
	master.volume = 0.0  # Master at unity gain (0 dB)
	master.color = Color.from_string("#333333", Color.WHITE)
	channels.append(master)


# ============================================================================
# AUDIO ENGINE SYNC
# ============================================================================

func connect_to_engine() -> void:
	"""Connect project and all data to audio engine."""
	if _connection_state != ConnectionState.DISCONNECTED:
		print("[Project] Already connected or connecting (state: %d)" % _connection_state)
		return

	# Set state to CONNECTING immediately (before any async operations)
	_connection_state = ConnectionState.CONNECTING
	connection_state_changed.emit(ConnectionState.CONNECTING)
	print("[Project] Connecting to audio engine...")

	# Listen for engine connection confirmation
	if not AudioEngineOSC.engine_connected.is_connected(_on_engine_confirmed_connected):
		AudioEngineOSC.engine_connected.connect(_on_engine_confirmed_connected)
	
	# Listen for engine disconnection
	if not AudioEngineOSC.engine_disconnected.is_connected(_on_engine_disconnected):
		AudioEngineOSC.engine_disconnected.connect(_on_engine_disconnected)

	# Register OSC listeners for clip/audiofile events
	_register_clip_osc_listeners()

	# Clear any previous project state in engine, then initialize
	AudioEngineOSC.send("/project/clear", [])
	AudioEngineOSC.send("/project/init", [tempo, time_numerator, time_denominator, ppq, sample_rate])
	
	# Check if engine is already connected (signal may have fired before we connected to it)
	# If so, the /project/init won't send back /status/connected, so we need to sync now
	if AudioEngineOSC._is_engine_connected:
		print("[Project] Engine already connected, waiting for /status/connected response")
		# Note: The /project/init command will still trigger a /status/connected response
		# which will call _on_engine_confirmed_connected via the signal


func _on_engine_confirmed_connected() -> void:
	"""Called when engine confirms it's ready (after receiving /status/connected)."""
	if _connection_state == ConnectionState.CONNECTED:
		return  # Already connected
	
	print("[Project] Engine confirmed connection, syncing project data...")
	
	# Mark as connected so sync methods work
	_connection_state = ConnectionState.CONNECTED
	connection_state_changed.emit(ConnectionState.CONNECTED)

	# Sync all clips to engine (must happen before tracks, since tracks reference clips)
	for clip_id in clips.keys():
		_sync_clip_to_engine(clips[clip_id])

	# Connect all channels
	for channel in channels:
		channel.connect_to_engine()

	# Connect all tracks (this will sync clip instances which reference the clips)
	for track in tracks:
		track.connect_to_engine()

	print("[Project] Connected to audio engine")


func _on_engine_disconnected() -> void:
	"""Called when engine connection is lost (heartbeat timeout)."""
	if _connection_state == ConnectionState.DISCONNECTED:
		return  # Already disconnected
	
	print("[Project] Engine connection lost!")
	_connection_state = ConnectionState.DISCONNECTED
	connection_state_changed.emit(ConnectionState.DISCONNECTED)


func _register_clip_osc_listeners() -> void:
	_unregister_osc_listeners()
	_register_osc_listener("/clip/*/load_state", _on_clip_load_state_received)
	_register_osc_listener("/audiofile/decode/ready", _on_audiofile_decode_ready)
	_register_osc_listener("/audiofile/waveform/level", _on_audiofile_waveform_level)
	_register_osc_listener("/audiofile/progress", _on_audiofile_progress)
	_register_osc_listener("/audiofile/error", _on_audiofile_error)


func _register_osc_listener(address: String, callback: Callable) -> void:
	AudioEngineOSC.listen(address, callback)
	_osc_listener_registry.append({
		"address": address,
		"callback": callback
	})


func _unregister_osc_listeners() -> void:
	for entry in _osc_listener_registry:
		var address: String = entry.get("address", "")
		var callback: Callable = entry.get("callback")
		if not address.is_empty() and callback and callback.is_valid():
			AudioEngineOSC.unlisten(address, callback)
	_osc_listener_registry.clear()


func _record_clip_request(clip_id: String, req_id: String) -> void:
	if clip_id.is_empty() or req_id.is_empty():
		return
	_clip_request_lookup[clip_id] = req_id
	_request_clip_lookup[req_id] = clip_id
	print("[Project] Tracked clip request", clip_id, "->", req_id)


func _clear_clip_request_by_req(req_id: String) -> void:
	if req_id.is_empty():
		return
	if _request_clip_lookup.has(req_id):
		var clip_id: String = _request_clip_lookup[req_id]
		print("[Project] Clearing clip request", clip_id, "for", req_id)
		_request_clip_lookup.erase(req_id)
		_clip_request_lookup.erase(clip_id)


func _get_clip_by_req_id(req_id: String) -> Clip:
	if _request_clip_lookup.has(req_id):
		return get_clip(_request_clip_lookup[req_id])
	return null


## Remember which DeviceInstance owns an AudioFileService request (sampler waveforms).
func track_device_request(device: DeviceInstance, req_id: String) -> void:
	if device == null or req_id.is_empty():
		return
	_request_device_lookup[req_id] = device


func _get_device_by_req_id(req_id: String) -> DeviceInstance:
	if _request_device_lookup.has(req_id):
		return _request_device_lookup[req_id] as DeviceInstance
	return null


func _get_scene_tree() -> SceneTree:
	return Sonara.editor.get_tree()

func _on_clip_load_state_received(args: Array, address: String) -> void:
	if address.is_empty():
		return
	var parts := address.split("/")
	if parts.size() < 3:
		return
	var clip_id := parts[2]
	print("[Project] load_state", args, "from", address)
	var clip := get_clip(clip_id)
	if clip == null:
		print("[Project] Received load_state for unknown clip: ", clip_id)
		return

	var state_label: String = str(args[0]) if args.size() > 0 else ""
	var req_id: String = str(args[1]) if args.size() > 1 else ""
	var source_path: String = str(args[2]) if args.size() > 2 else clip.audio_file_path
	var cache_key: String = str(args[3]) if args.size() > 3 else clip.waveform_cache_key
	var clip_sample_rate: int = int(args[4]) if args.size() > 4 else clip.audio_sample_rate
	var clip_channels: int = int(args[5]) if args.size() > 5 else clip.audio_channels
	var message: String = str(args[6]) if args.size() > 6 else ""

	clip.audio_file_path = source_path
	if clip_sample_rate > 0 or clip_channels > 0:
		clip.set_audio_metadata(clip_sample_rate, max(1, clip_channels), clip.audio_frames)
	clip.waveform_cache_key = cache_key

	var new_state: Clip.LoadState = Clip.LoadState.UNLOADED
	match state_label:
		"loading":
			new_state = Clip.LoadState.LOADING
		"ready":
			new_state = Clip.LoadState.READY
		"failed":
			new_state = Clip.LoadState.FAILED
		_:
			new_state = Clip.LoadState.UNLOADED

	if not req_id.is_empty():
		_record_clip_request(clip_id, req_id)

	match new_state:
		Clip.LoadState.LOADING:
			clip.mark_load_started(req_id, source_path)
		Clip.LoadState.READY:
			clip.apply_load_state(Clip.LoadState.READY, req_id, "")
			clip.update_load_progress(1.0)
			clip.update_content_length_from_metadata(tempo, ppq)
		Clip.LoadState.FAILED:
			clip.apply_load_state(Clip.LoadState.FAILED, req_id, message)
			clip.update_load_progress(0.0)
			_clear_clip_request_by_req(req_id)
		Clip.LoadState.UNLOADED:
			clip.apply_load_state(Clip.LoadState.UNLOADED, req_id, "")
			clip.update_load_progress(0.0)
			_clear_clip_request_by_req(req_id)


func _on_audiofile_decode_ready(args: Array) -> void:
	"""Handle OSC /audiofile/decode/ready event from audio engine.

	Called when audio file decoding completes. Updates clip with decoded audio metadata
	(sample rate, channels, frame count, duration) and locates the waveform cache file.

	Progressive flow:
	  1. This handler fires when decoding completes
	  2. Subsequent /audiofile/waveform/level events load each resolution level
	  3. UI renders waveforms progressively as each level loads

	OSC args: [req_id, cache_key, channels, frames, sample_rate, duration_s, sample_count?]
	"""
	if args.size() < 6:
		push_error("[Project] decode_ready: Insufficient arguments (need 6, got %d)" % args.size())
		return

	var req_id := str(args[0])
	var clip := _get_clip_by_req_id(req_id)
	if clip == null:
		_apply_device_decode_ready(req_id, args)
		return

	var cache_key: String = str(args[1])
	var decoded_channels: int = int(args[2])
	var frames: int = int(args[3])
	var decoded_sample_rate: int = int(args[4])
	var duration_s: float = float(args[5])
	var sample_count: int = int(args[6]) if args.size() > 6 else 0

	# Calculate frames if not provided
	if frames <= 0:
		if sample_count > 0 and decoded_channels > 0:
			# Calculate from sample count (total interleaved samples / channels)
			@warning_ignore("integer_division")
			frames = sample_count / decoded_channels
		elif duration_s > 0.0 and decoded_sample_rate > 0:
			# Fallback: calculate from duration
			frames = int(duration_s * float(decoded_sample_rate))

	# If duration is 0 but we have frames and sample rate, calculate it
	if duration_s <= 0.0 and frames > 0 and decoded_sample_rate > 0:
		duration_s = float(frames) / float(decoded_sample_rate)

	clip.waveform_cache_key = cache_key

	# Locate waveform cache file from standard locations
	var cache_path = Sonara.find_waveform_cache_file(cache_key)
	if not cache_path.is_empty():
		clip.set_waveform_cache(cache_path, cache_key)
	else:
		push_warning("[Project] Waveform cache not found: %s" % cache_key)

	# Update clip with decoded audio metadata
	clip.set_audio_metadata(decoded_sample_rate, decoded_channels, frames, duration_s)

	# If waveform levels already arrived before metadata, update metadata now
	if clip.audio_waveform and clip.audio_waveform.levels.size() > 0:
		clip.audio_waveform.set_metadata(frames, decoded_sample_rate, decoded_channels)

	clip.update_content_length_from_metadata(tempo, ppq)


## Apply AFS decode metadata to a sampler DeviceInstance.
func _apply_device_decode_ready(req_id: String, args: Array) -> void:
	var inst := _get_device_by_req_id(req_id)
	if inst == null:
		return
	if inst.sample_waveform == null:
		inst.sample_waveform = DeviceWaveform.new()
	var cache_key: String = str(args[1])
	var decoded_channels: int = int(args[2])
	var frames: int = int(args[3])
	var decoded_sample_rate: int = int(args[4])
	var duration_s: float = float(args[5])
	var cache_path := Sonara.find_waveform_cache_file(cache_key)
	if not cache_path.is_empty():
		inst.sample_waveform.set_waveform_cache(cache_path, cache_key)
	inst.sample_waveform.set_audio_metadata(decoded_sample_rate, decoded_channels, frames, duration_s)


## Ingest one waveform pyramid level into a sampler DeviceInstance.
func _apply_device_waveform_level(req_id: String, args: Array) -> void:
	var inst := _get_device_by_req_id(req_id)
	if inst == null:
		return
	if inst.sample_waveform == null:
		inst.sample_waveform = DeviceWaveform.new()
	var level := int(args[1])
	var block_size := int(args[2])
	var num_blocks := int(args[3]) if args.size() >= 4 else 0
	var file_path := str(args[4]) if args.size() >= 5 else ""
	if file_path.is_empty() and not inst.sample_waveform.waveform_cache_path.is_empty():
		file_path = inst.sample_waveform.waveform_cache_path
	if not file_path.is_empty():
		if inst.sample_waveform.waveform_cache_key.is_empty():
			inst.sample_waveform.waveform_cache_key = file_path.get_file()
		inst.sample_waveform.set_waveform_cache(file_path, inst.sample_waveform.waveform_cache_key)
	inst.sample_waveform.ensure_audio_waveform()
	inst.sample_waveform.ingest_waveform_level_from_cache(level, block_size, num_blocks)


func _on_audiofile_waveform_level(args: Array) -> void:
	"""Handle OSC /audiofile/waveform/level event from audio engine.

	Called progressively as each waveform resolution level becomes available during
	processing. Ingests peak/RMS data into the clip's multi-resolution pyramid.

	Supports variable argument count (engine may send 3-5+ arguments):
	  [req_id, level, block_size, num_blocks?, file_path?]

	If num_blocks or file_path are missing, reads them from the cache file.
	Implements retry logic with exponential backoff if ingestion fails.

	OSC args: [req_id, level, block_size, num_blocks?, file_path?]
	"""
	# Minimum required: req_id, level, block_size
	if args.size() < 3:
		push_error("[Project] Waveform level: Insufficient arguments (got %d, need 3)" % args.size())
		return

	var req_id := str(args[0])
	var clip := _get_clip_by_req_id(req_id)
	if clip == null:
		_apply_device_waveform_level(req_id, args)
		return

	var level := int(args[1])
	var block_size := int(args[2])
	var num_blocks := 0
	var file_path := ""

	# Parse remaining arguments: num_blocks, file_path, byte_offset, byte_len
	# Engine sends: [req_id, level, block_size, num_blocks, file_path, byte_offset, byte_len]
	if args.size() >= 4:
		num_blocks = int(args[3])
	if args.size() >= 5:
		file_path = str(args[4])
	# byte_offset and byte_len are in args[5] and args[6] if present, but not currently used

	# Fallback to cached file path
	if file_path.is_empty() and not clip.waveform_cache_path.is_empty():
		file_path = clip.waveform_cache_path

	# Update cache path if provided
	if not file_path.is_empty():
		if clip.waveform_cache_key.is_empty():
			clip.waveform_cache_key = file_path.get_file()
		clip.set_waveform_cache(file_path, clip.waveform_cache_key)

	# Ensure waveform object exists
	clip.ensure_audio_waveform()

	# Try to ingest level data, retry if fails
	if not clip.ingest_waveform_level_from_cache(level, block_size, num_blocks):
		_schedule_waveform_retry(req_id, level, block_size, num_blocks, file_path)
	else:
		# Successfully loaded - UI will render progressively
		pass


func _on_audiofile_progress(args: Array) -> void:
	"""Handle OSC /audiofile/progress event from audio engine.

	Updates loading progress (0.0 to 1.0) for long-running decode/waveform
	generation tasks, enabling UI progress indication.

	OSC args: [req_id, progress_0_1]
	"""
	if args.size() < 2:
		return
	var req_id := str(args[0])
	var clip := _get_clip_by_req_id(req_id)
	if clip == null:
		return
	var progress := float(args[1])
	clip.update_load_progress(progress)


func _on_audiofile_error(args: Array) -> void:
	"""Handle OSC /audiofile/error event from audio engine.

	Called when audio decoding or waveform generation fails. Updates clip with
	error state and message for UI feedback.

	OSC args: [req_id, error_code, error_message]
	"""
	if args.size() < 3:
		return
	var req_id := str(args[0])
	var clip := _get_clip_by_req_id(req_id)
	if clip == null:
		_request_device_lookup.erase(req_id)
		return
	var code := int(args[1])
	var message := str(args[2])
	clip.apply_load_state(Clip.LoadState.FAILED, req_id, "[%d] %s" % [code, message])
	_clear_clip_request_by_req(req_id)


func _schedule_waveform_retry(req_id: String, level: int, block_size: int, num_blocks: int, file_path: String, attempt: int = 1) -> void:
	"""Schedule a retry attempt for failed waveform level ingestion.

	Implements exponential backoff: delay = 0.25s * attempt_number (capped at 3 attempts).
	Useful for handling transient cache file access issues.

	Args:
		req_id: Audio file service request ID
		level: Waveform resolution level
		block_size: Samples per block
		num_blocks: Number of blocks in this level
		file_path: Optional cache file path
		attempt: Current attempt number (1-based)
	"""
	var key := "%s:%d" % [req_id, level]
	var info: Dictionary = _pending_waveform_retries.get(key, {})
	var current_attempt: int = int(info.get("attempt", 0))

	# Cap at 3 attempts
	if current_attempt >= 3:
		push_warning("[Project] Waveform retry: Max attempts reached for level %d" % level)
		return

	var next_attempt: int = int(max(attempt, current_attempt + 1))
	_pending_waveform_retries[key] = {
		"attempt": next_attempt,
		"block_size": block_size,
		"num_blocks": num_blocks,
		"file_path": file_path
	}

	# Exponential backoff: 0.25s * attempt number
	var delay: float = 0.25 * float(next_attempt)
	var scene_tree := _get_scene_tree()
	if scene_tree == null:
		return

	var timer = scene_tree.create_timer(delay)
	timer.timeout.connect(_on_waveform_retry_timeout.bind(req_id, level))


func _on_waveform_retry_timeout(req_id: String, level: int) -> void:
	"""Timeout callback for waveform retry attempt.

	Re-attempts waveform level ingestion after delay. Reads num_blocks from
	cache if not available, and schedules another retry if still failing.
	"""
	var key := "%s:%d" % [req_id, level]

	if not _pending_waveform_retries.has(key):
		return

	var info: Dictionary = _pending_waveform_retries[key]
	var clip := _get_clip_by_req_id(req_id)

	if clip == null:
		_pending_waveform_retries.erase(key)
		return

	var block_size := int(info.get("block_size", 0))
	var num_blocks := int(info.get("num_blocks", 0))

	# Try to read num_blocks from cache if still not available
	if num_blocks <= 0 and not clip.waveform_cache_path.is_empty():
		var reader = WaveformCacheReader.new()
		if reader.load(clip.waveform_cache_path):
			var level_info = reader.read_level(level, clip.audio_channels)
			if not level_info.is_empty():
				num_blocks = int(level_info.get("num_blocks", 0))

	# Ensure cache path is available
	if clip.waveform_cache_path.is_empty() and not clip.waveform_cache_key.is_empty():
		var cache_path = Sonara.find_waveform_cache_file(clip.waveform_cache_key)
		if not cache_path.is_empty():
			clip.set_waveform_cache(cache_path, clip.waveform_cache_key)

	# Retry ingestion
	if clip.ingest_waveform_level_from_cache(level, block_size, num_blocks):
		_pending_waveform_retries.erase(key)
	else:
		# Check if we should retry again
		var attempt := int(info.get("attempt", 1))
		if attempt >= 3:
			_pending_waveform_retries.erase(key)
			push_error("[Project] Waveform retry: Failed after %d attempts for level %d" % [attempt, level])
		else:
			_schedule_waveform_retry(req_id, level, block_size, num_blocks, "", attempt + 1)


func disconnect_from_engine() -> void:
	"""Disconnect project and all data from audio engine."""
	if _connection_state == ConnectionState.DISCONNECTED:
		return

	print("[Project] Disconnecting from audio engine...")

	# Disconnect signal listeners
	if AudioEngineOSC.engine_connected.is_connected(_on_engine_confirmed_connected):
		AudioEngineOSC.engine_connected.disconnect(_on_engine_confirmed_connected)
	if AudioEngineOSC.engine_disconnected.is_connected(_on_engine_disconnected):
		AudioEngineOSC.engine_disconnected.disconnect(_on_engine_disconnected)

	_unregister_osc_listeners()
	_clip_request_lookup.clear()
	_request_clip_lookup.clear()
	_pending_waveform_retries.clear()
	for clip in clips.values():
		if clip and clip.type == Clip.ClipType.AUDIO:
			clip.apply_load_state(Clip.LoadState.UNLOADED, "", "Disconnected")
			clip.update_load_progress(0.0)

	# Disconnect all tracks
	for track in tracks:
		track.disconnect_from_engine()

	# Disconnect all channels
	for channel in channels:
		channel.disconnect_from_engine()

	# Clear project (this clears clips, tracks, channels from engine)
	AudioEngineOSC.send("/project/clear", [])

	# Reset AudioEngineOSC connection state
	AudioEngineOSC.reset_connection()

	_connection_state = ConnectionState.DISCONNECTED
	connection_state_changed.emit(ConnectionState.DISCONNECTED)
	print("[Project] Disconnected from audio engine")


func _sync_clip_to_engine(clip: Clip) -> void:
	"""Sync a clip and its MIDI notes or audio data to the audio engine."""
	if _connection_state != ConnectionState.CONNECTED:
		print("[Project] WARNING: _sync_clip_to_engine called but not connected!")
		return

	# Create clip in engine
	var clip_type_str = "midi" if clip.type == Clip.ClipType.MIDI else "audio"
	print("[Project] Creating %s clip in engine: %s" % [clip_type_str, clip.id])
	AudioEngineOSC.send("/clip/create", [clip.id, clip_type_str, clip.name])
	# Mark as synced locally so subsequent updates (move/resize) don't warn
	clip._synced_to_engine = true

	# Sync MIDI notes (if MIDI clip)
	if clip.type == Clip.ClipType.MIDI:
		print("[Project] Syncing %d MIDI notes for clip: %s" % [clip.midi_notes.size(), clip.id])
		for note in clip.midi_notes:
			print("[Project]   - Note %d: pitch=%d start=%d dur=%d" % [note.id, note.note, note.start_tick, note.duration_ticks])
			AudioEngineOSC.send("/clip/%s/add_note" % clip.id, [
				note.id,
				note.note,
				note.start_tick,
				note.duration_ticks,
				note.velocity
			])
	else:
		# Sync audio data (if audio clip)
		if not clip.audio_file_path.is_empty():
			var sample_rate_hint: int = clip.audio_sample_rate if clip.audio_sample_rate > 0 else 0
			var channel_hint: int = clip.audio_channels if clip.audio_channels > 0 else 0
			print("[Project] Requesting engine-side load for clip %s (%s)" % [clip.id, clip.audio_file_path])
			clip.apply_load_state(Clip.LoadState.LOADING, "", "")
			clip.load_progress = 0.0
			var prev_req_id: String = _clip_request_lookup.get(clip.id, "")
			if not prev_req_id.is_empty():
				_clear_clip_request_by_req(prev_req_id)
			AudioEngineOSC.send("/clip/%s/load_audio_file" % clip.id, [
				clip.audio_file_path,
				sample_rate_hint,
				channel_hint
			])
		else:
			print("[Project] WARNING: Audio clip %s has no audio_file_path!" % clip.id)


# ============================================================================
# CHANNEL MANAGEMENT
# ============================================================================
func add_channel(channel: Channel) -> void:
	"""Add an existing channel to the project."""
	channels.append(channel)
	channel_added.emit(channel)

	# Auto-connect if project is connected
	if _connection_state == ConnectionState.CONNECTED:
		channel.connect_to_engine()


func create_channel(channel_name: String = "Channel", channel_type: Channel.ChannelType = Channel.ChannelType.BUS) -> Channel:
	"""Create a new channel with unique ID and add to project."""
	var channel = Channel.new(next_channel_id)
	next_channel_id += 1

	channel.name = channel_name
	channel.channel_type = channel_type
	channel.output_channel_id = 1  # Route to master (ID 1) by default
	channel.color = _generate_random_color()
	add_channel(channel)

	return channel


func get_master_channel() -> Channel:
	"""Get the master channel (always ID 1, index 0)."""
	return channels[0] if not channels.is_empty() else null


func get_channel_by_id(channel_id: int) -> Channel:
	"""Find channel by ID."""
	for channel in channels:
		if channel.id == channel_id:
			return channel
	return null


func remove_channel(channel_id: int) -> bool:
	"""Remove a channel from the project. Returns true if successful."""
	var channel = get_channel_by_id(channel_id)
	if not channel:
		return false
	
	# Prevent removing the master channel
	if channel.is_master:
		print("[Project] Cannot remove master channel")
		return false
	
	# Reroute any tracks that were using this channel to the master channel
	for track in channel.routed_tracks.duplicate():
		# Temporarily disable name/color syncing so track keeps its original identity
		var old_name_by_channel = track.name_by_channel
		var old_color_by_channel = track.color_by_channel
		track.name_by_channel = false
		track.color_by_channel = false
		
		track.default_channel_id = 1  # Route to master (ID 1)
		
		# Restore sync settings
		track.name_by_channel = old_name_by_channel
		track.color_by_channel = old_color_by_channel
		
		print("[Project] Track '%s' rerouted to Master (was using removed channel %d)" % [track.name, channel_id])
	
	# Reroute any channels that were routing to this channel to the master channel
	for ch in channels:
		if ch.output_channel_id == channel_id:
			ch.set_route(1)  # Route to master (ID 1)
			print("[Project] Channel '%s' rerouted to Master (was routing to removed channel %d)" % [ch.name, channel_id])
	
	# Disconnect from engine if connected
	if _connection_state == ConnectionState.CONNECTED and channel._is_connected:
		channel.disconnect_from_engine()
		# Tell engine to remove the channel
		AudioEngineOSC.send("/channel/%d/remove" % channel_id, [])
	
	# Remove from channels array
	var index = channels.find(channel)
	if index >= 0:
		channels.remove_at(index)
	
	# Emit signal before cleanup
	channel_removed.emit(channel)
	
	print("[Project] Channel removed: %s (ID: %d)" % [channel.name, channel_id])
	return true


# ============================================================================
# TRACK MANAGEMENT
# ============================================================================

func add_track(track: Track) -> void:
	"""Add an existing track to the project."""
	# Set order relative to siblings
	var sibling_count = 0
	for t in tracks:
		if t.parent_track_id == track.parent_track_id:
			sibling_count += 1
	track.order = sibling_count
	
	# Set project reference for channel linking
	track.set_project_ref(self)
	
	tracks.append(track)
	track_added.emit(track)

	# Auto-connect if project is connected
	if _connection_state == ConnectionState.CONNECTED:
		track.connect_to_engine()


func create_track(track_name: String = "Track") -> Track:
	"""Create a new track with unique ID and add to project."""
	var track = Track.new(next_track_id)
	next_track_id += 1

	track.name = track_name
	add_track(track)

	return track


func get_track_by_id(track_id: int) -> Track:
	"""Find track by ID."""
	for track in tracks:
		if track.id == track_id:
			return track
	return null


func remove_track(track_id: int) -> bool:
	"""Remove a track from the project. Returns true if successful."""
	var track = get_track_by_id(track_id)
	if not track:
		return false
	
	# If it's a folder, recursively remove children first
	if track.type == Track.TrackType.FOLDER:
		# Make a copy of child_track_ids since we'll be modifying it
		var children_to_remove = track.child_track_ids.duplicate()
		for child_id in children_to_remove:
			remove_track(child_id)
	
	# Remove from parent's child list if applicable
	if track.parent_track_id >= 0:
		var parent = get_track_by_id(track.parent_track_id)
		if parent:
			parent.child_track_ids.erase(track_id)
			# Renumber remaining siblings
			_renumber_siblings(track.parent_track_id)
	else:
		# Was a root track, renumber root siblings
		_renumber_siblings(-1)
	
	# Disconnect from engine if connected
	if _connection_state == ConnectionState.CONNECTED and track._is_connected:
		track.disconnect_from_engine()
	
	# Remove from tracks array
	var index = tracks.find(track)
	if index >= 0:
		tracks.remove_at(index)
	
	# Emit signal before cleanup
	track_removed.emit(track)
	
	print("[Project] Track removed: %s (ID: %d)" % [track.name, track_id])
	return true


func get_track_children(track: Track) -> Array[Track]:
	"""Get direct children of a track (not recursive)."""
	var children: Array[Track] = []
	if track == null or track.type != Track.TrackType.FOLDER:
		return children
	for t in tracks:
		if t.parent_track_id == track.id:
			children.append(t)
	children.sort_custom(func(a, b): return a.order < b.order)
	return children


func get_track_siblings(track: Track) -> Array[Track]:
	"""Get sibling tracks (tracks with same parent)."""
	var siblings: Array[Track] = []
	for t in tracks:
		if t != track and t.parent_track_id == track.parent_track_id:
			siblings.append(t)
	# Sort by order
	siblings.sort_custom(func(a, b): return a.order < b.order)
	return siblings


func get_visual_track_list() -> Array[Track]:
	"""Build a flat list of tracks in visual order from the hierarchy."""
	var result: Array[Track] = []
	
	# Get root tracks (no parent)
	var root_tracks: Array[Track] = []
	for track in tracks:
		if track.parent_track_id < 0:
			root_tracks.append(track)
	
	# Sort root tracks by order
	root_tracks.sort_custom(func(a, b): return a.order < b.order)
	
	# Recursively add each root and its descendants
	for root in root_tracks:
		_add_track_and_descendants_to_list(root, result)
	
	return result


func _add_track_and_descendants_to_list(track: Track, result: Array[Track]) -> void:
	"""Recursively add a track and all its descendants to a list."""
	result.append(track)
	
	if track.type == Track.TrackType.FOLDER:
		var children = get_track_children(track)
		for child in children:
			_add_track_and_descendants_to_list(child, result)


# ============================================================================
# CLIP POOL MANAGEMENT
# ============================================================================

func create_clip(clip_name: String = "Clip", clip_type: Clip.ClipType = Clip.ClipType.MIDI) -> Clip:
	"""Create a new clip with unique ID (but don't add to pool yet - caller must call add_clip() after loading data)."""
	var clip = Clip.new()  # Clip generates its own GUID
	clip.name = clip_name
	clip.type = clip_type
	return clip


func add_clip(clip: Clip) -> void:
	"""Add an existing clip to the pool."""
	if clip.id.is_empty():
		push_error("[Project] Cannot add clip with empty ID")
		return

	if clips.has(clip.id):
		push_warning("[Project] Clip with ID %s already exists, replacing" % clip.id)

	clips[clip.id] = clip
	print("[Project] Added clip to pool: %s (total clips: %d)" % [clip.id, clips.size()])

	# Sync to engine if connected
	if _connection_state == ConnectionState.CONNECTED:
		_sync_clip_to_engine(clip)

	clip_added.emit(clip)


func get_clip(clip_id: String) -> Clip:
	"""Get clip by ID from pool."""
	return clips.get(clip_id, null)


func create_clip_from_asset(asset: Asset, default_color: Color = Color.WHITE) -> Clip:
	"""Create a clip (audio or MIDI) from an Asset."""
	var clip_type = Clip.ClipType.AUDIO if asset.is_audio() else Clip.ClipType.MIDI
	var clip = create_clip(asset.get_display_name(), clip_type)
	clip.color = default_color.lightened(0.2)
	clip.audio_file_path = asset.path

	if clip_type == Clip.ClipType.AUDIO:
		clip.audio_file_path = asset.path
		clip.audio_sample_rate = 0
		clip.audio_channels = 0
		clip.audio_frames = 0
		clip.audio_duration_seconds = 0.0
		clip.waveform_cache_key = ""
		clip.waveform_cache_path = ""
		clip.apply_load_state(Clip.LoadState.UNLOADED, "", "")
		clip.load_progress = 0.0
		clip.content_length_ticks = ppq * 4  # Placeholder until engine provides length
	else:
		# TODO: Load MIDI notes from asset.path when MIDI parser is available
		clip.content_length_ticks = ppq * 4  # Default 4 beats

	# Add clip to pool AFTER metadata is prepared
	add_clip(clip)

	return clip


func remove_clip(clip_id: String) -> bool:
	"""Remove clip from pool. Returns true if clip was found and removed."""
	if not clips.has(clip_id):
		return false

	# TODO: Check if any instances reference this clip and warn/prevent deletion
	# For now, just remove it
	var req_id: String = _clip_request_lookup.get(clip_id, "")
	if not req_id.is_empty():
		_clear_clip_request_by_req(req_id)

	# Remove from engine if connected
	if _connection_state == ConnectionState.CONNECTED:
		AudioEngineOSC.send("/clip/delete", [clip_id])

	clips.erase(clip_id)
	clip_removed.emit(clip_id)
	return true


func get_clip_instance_count(clip_id: String) -> int:
	"""Count how many instances reference this clip across all tracks."""
	var count = 0
	for track in tracks:
		for instance in track.clip_instances:
			if instance.clip_id == clip_id:
				count += 1
	return count


# ============================================================================
# CONVENIENCE METHODS
# ============================================================================

# Create instrument track with corresponding channel
func create_instrument_track(track_name: String = "Instrument") -> Dictionary:
	"""Create a track + channel pair for an instrument."""
	var track = create_track(track_name)
	track.type = Track.TrackType.INSTRUMENT

	var channel = create_channel(track_name, Channel.ChannelType.INSTRUMENT)

	track.default_channel_id = channel.id  # Setter auto-reconnects if needed
	
	# Connect track to engine now that it has a valid channel
	if _connection_state == ConnectionState.CONNECTED:
		track.connect_to_engine()

	return {"track": track, "channel": channel}


# Create audio track with corresponding channel
func create_audio_track(track_name: String = "Audio") -> Dictionary:
	"""Create a track + channel pair for audio."""
	var track = create_track(track_name)
	track.type = Track.TrackType.AUDIO

	var channel = create_channel(track_name, Channel.ChannelType.AUDIO)

	track.default_channel_id = channel.id  # Setter auto-reconnects if needed
	
	# Connect track to engine now that it has a valid channel
	if _connection_state == ConnectionState.CONNECTED:
		track.connect_to_engine()

	return {"track": track, "channel": channel}


# Create bus channel (no track)
func create_bus_channel(bus_name: String = "Bus") -> Channel:
	"""Create a bus channel (routing only, no track)."""
	return create_channel(bus_name, Channel.ChannelType.BUS)


## Create a group track: a folder paired with a dedicated mixer bus.
func create_group_track(group_name: String = "Group") -> Dictionary:
	return create_folder_track(group_name, true)


## Create a folder track. `with_channel` true makes it a group (dedicated bus).
func create_folder_track(folder_name: String = "Folder", with_channel: bool = false) -> Dictionary:
	var track = Track.new(next_track_id)
	next_track_id += 1
	track.type = Track.TrackType.FOLDER
	track.height = 60
	track.set_project_ref(self)

	var channel = null
	if with_channel:
		channel = create_channel(folder_name, Channel.ChannelType.BUS)
		track.pair_mixer_channel(channel)
	else:
		track.color_by_channel = false
		track.name_by_channel = false

	track.name = folder_name
	add_track(track)
	print("[Project] %s '%s' (track %d) bus=%s" % [
		"Group" if with_channel else "Folder",
		track.name,
		track.id,
		("%d" % channel.id) if channel else "none"
	])
	return {"track": track, "channel": channel}


## Mixer bus of the nearest ancestor group, or null if none.
func get_enclosing_group_bus(track: Track) -> Channel:
	if track == null:
		return null
	var parent_id := track.parent_track_id
	while parent_id >= 0:
		var parent := get_track_by_id(parent_id)
		if parent == null:
			break
		if parent.is_group():
			return parent.get_linked_channel()
		parent_id = parent.parent_track_id
	return null


## Mixer channel this track owns (instrument/audio strip or group bus).
func get_track_mixer_channel(track: Track) -> Channel:
	if track == null or track.default_channel_id < 0:
		return null
	return get_channel_by_id(track.default_channel_id)


## Route this track's mixer channel to the enclosing group bus, or Master.
func sync_track_hierarchy_routing(track: Track) -> void:
	var ch := get_track_mixer_channel(track)
	if ch == null or ch.is_master:
		return
	var bus := get_enclosing_group_bus(track)
	var target_id := bus.id if bus else 1
	if ch.id == target_id:
		return
	if ch.output_channel_id != target_id:
		ch.set_route(target_id)


## Route a folder and every descendant according to group ancestry.
func sync_subtree_hierarchy_routing(track: Track) -> void:
	if track == null:
		return
	sync_track_hierarchy_routing(track)
	if track.type != Track.TrackType.FOLDER:
		return
	for child in get_track_children(track):
		sync_subtree_hierarchy_routing(child)


## Pair a folder with a bus (making it a group) and route descendants to that bus.
func link_folder_to_bus(track: Track, bus: Channel) -> void:
	if track == null or bus == null or track.type != Track.TrackType.FOLDER:
		return
	track.color_by_channel = true
	track.name_by_channel = true
	track.pair_mixer_channel(bus)
	sync_subtree_hierarchy_routing(track)


## Turn a group back into a channel-less folder and re-route descendants.
func unlink_folder_from_bus(track: Track) -> void:
	if track == null or track.type != Track.TrackType.FOLDER:
		return
	track.color_by_channel = false
	track.name_by_channel = false
	track.default_channel_id = -1
	sync_subtree_hierarchy_routing(track)


## Create a bus named and colored like the folder, pair it, and route children.
func create_and_link_folder_bus(track: Track) -> Channel:
	if track == null or track.type != Track.TrackType.FOLDER:
		return null
	var bus := create_bus_channel(track.name)
	bus.set_color(track.get_color())
	bus.set_name(track.name)
	link_folder_to_bus(track, bus)
	return bus


## Add a track as the last child of a folder.
func add_track_to_folder(track_id: int, folder_id: int) -> bool:
	var track = get_track_by_id(track_id)
	var folder = get_track_by_id(folder_id)
	if not track or not folder or folder.type != Track.TrackType.FOLDER:
		return false
	var after_sibling: Track = null
	for child in get_track_children(folder):
		if child != track:
			after_sibling = child
	return place_track(track, folder_id, after_sibling)


## True while place_track / apply_track_layout is mutating multiple tracks.
func is_track_layout_batching() -> bool:
	return _track_layout_batch > 0


## Suppress per-track UI rebuilds until end_track_layout_batch().
func begin_track_layout_batch() -> void:
	_track_layout_batch += 1


## End a layout batch and notify TrackList/Timeline once.
func end_track_layout_batch() -> void:
	_track_layout_batch -= 1
	if _track_layout_batch > 0:
		return
	_track_layout_batch = 0
	tracks_layout_changed.emit()


## Move `track` under `new_parent_id`, sitting after `after_sibling` (null = first child / first root).
func place_track(track: Track, new_parent_id: int, after_sibling: Track = null) -> bool:
	if track == null:
		return false
	if after_sibling == track:
		return false
	if new_parent_id == track.id:
		return false
	if track_is_in_subtree(new_parent_id, track):
		return false

	if new_parent_id >= 0:
		var new_parent := get_track_by_id(new_parent_id)
		if new_parent == null or new_parent.type != Track.TrackType.FOLDER:
			return false

	if after_sibling != null and after_sibling.parent_track_id != new_parent_id:
		return false

	if _track_already_placed(track, new_parent_id, after_sibling):
		return false

	begin_track_layout_batch()

	var old_parent_id := track.parent_track_id
	if old_parent_id >= 0:
		var old_parent := get_track_by_id(old_parent_id)
		if old_parent:
			old_parent.child_track_ids.erase(track.id)

	track.parent_track_id = new_parent_id

	var siblings: Array[Track] = []
	for t in tracks:
		if t != track and t.parent_track_id == new_parent_id:
			siblings.append(t)
	siblings.sort_custom(func(a, b): return a.order < b.order)

	var new_order: Array[Track] = []
	if after_sibling == null:
		new_order.append(track)
		new_order.append_array(siblings)
	else:
		var inserted := false
		for sibling in siblings:
			new_order.append(sibling)
			if sibling == after_sibling:
				new_order.append(track)
				inserted = true
		if not inserted:
			new_order.append(track)

	for i in range(new_order.size()):
		new_order[i].order = i

	_sync_folder_child_ids(new_parent_id)
	if old_parent_id != new_parent_id:
		_renumber_siblings(old_parent_id)
		_sync_folder_child_ids(old_parent_id)
		sync_subtree_hierarchy_routing(track)

	end_track_layout_batch()
	return true


## Restore parent/order/children from a TrackReorderCommand snapshot.
func apply_track_layout(layout: Dictionary) -> void:
	if layout.is_empty():
		return
	begin_track_layout_batch()
	for track in tracks:
		if not layout.has(track.id):
			continue
		var entry: Dictionary = layout[track.id]
		var child_ids: Array[int] = []
		child_ids.assign(entry["child_track_ids"])
		track.child_track_ids = child_ids
		track.parent_track_id = entry["parent_track_id"]
		track.order = entry["order"]
	for track in tracks:
		sync_track_hierarchy_routing(track)
	end_track_layout_batch()


## True if `maybe_descendant_id` is `root` or nested under it.
func track_is_in_subtree(maybe_descendant_id: int, root: Track) -> bool:
	if maybe_descendant_id < 0 or root == null:
		return false
	var walk_id := maybe_descendant_id
	var visited: Dictionary = {}
	while walk_id >= 0:
		if walk_id == root.id:
			return true
		if visited.has(walk_id):
			break
		visited[walk_id] = true
		var node := get_track_by_id(walk_id)
		if node == null:
			break
		walk_id = node.parent_track_id
	return false


## True if `track` already sits after `after_sibling` under `new_parent_id`.
func _track_already_placed(track: Track, new_parent_id: int, after_sibling: Track) -> bool:
	if track.parent_track_id != new_parent_id:
		return false
	var previous: Track = null
	var siblings: Array[Track] = []
	for t in tracks:
		if t.parent_track_id == new_parent_id:
			siblings.append(t)
	siblings.sort_custom(func(a, b): return a.order < b.order)
	for sibling in siblings:
		if sibling == track:
			return previous == after_sibling
		previous = sibling
	return false


## Keep a folder's child_track_ids in sibling order.
func _sync_folder_child_ids(parent_id: int) -> void:
	if parent_id < 0:
		return
	var folder := get_track_by_id(parent_id)
	if folder == null or folder.type != Track.TrackType.FOLDER:
		return
	var ids: Array[int] = []
	for child in get_track_children(folder):
		ids.append(child.id)
	folder.child_track_ids = ids


func _renumber_siblings(parent_id: int) -> void:
	"""Renumber all tracks with the same parent to have sequential order."""
	var siblings: Array[Track] = []
	for t in tracks:
		if t.parent_track_id == parent_id:
			siblings.append(t)
	
	# Sort by current order
	siblings.sort_custom(func(a, b): return a.order < b.order)
	
	# Renumber
	for i in range(siblings.size()):
		siblings[i].order = i


# ============================================================================
# SERIALIZATION
# ============================================================================

# Serialize to JSON
func to_json() -> Dictionary:
	# Serialize clip pool
	var clips_array = []
	print("[Project] Serializing %d clips from pool: %s" % [clips.size(), str(clips.keys())])
	for clip_id in clips.keys():
		print("[Project] Serializing clip: %s" % clip_id)
		clips_array.append(clips[clip_id].to_json())

	return {
		"tempo": tempo,
		"time_numerator": time_numerator,
		"time_denominator": time_denominator,
		"ppq": ppq,
		"sample_rate": sample_rate,
		"project_name": project_name,
		"created_date": created_date,
		"modified_date": modified_date,
		"next_channel_id": next_channel_id,
		"next_track_id": next_track_id,
		"next_clip_id": next_clip_id,
		"next_note_id": next_note_id,
		"clips": clips_array,
		"channels": channels.map(func(c): return c.to_json()),
		"tracks": tracks.map(func(t): return t.to_json())
	}


# Deserialize from JSON
static func from_json(data: Dictionary) -> Project:
	var project = Project.new()
	project.tempo = data.get("tempo", 120.0)
	project.time_numerator = data.get("time_numerator", 4)
	project.time_denominator = data.get("time_denominator", 4)
	project.ppq = data.get("ppq", 960)
	project.sample_rate = data.get("sample_rate", 48000)
	project.project_name = data.get("project_name", "Untitled")
	project.created_date = data.get("created_date", 0)
	project.modified_date = data.get("modified_date", 0)

	# Restore ID counters
	project.next_channel_id = data.get("next_channel_id", 1)
	project.next_track_id = data.get("next_track_id", 0)
	project.next_clip_id = data.get("next_clip_id", 1)
	project.next_note_id = data.get("next_note_id", 1)

	# Load clip pool (must load before tracks, since tracks reference clips)
	project.clips.clear()
	for clip_data in data.get("clips", []):
		var clip = Clip.from_json(clip_data)
		project.clips[clip.id] = clip

	# Clear default master and load channels
	project.channels.clear()
	for channel_data in data.get("channels", []):
		project.channels.append(Channel.from_json(channel_data))

	# Load tracks
	for track_data in data.get("tracks", []):
		var track = Track.from_json(track_data)
		# Resolve clip references for clip instances
		for instance in track.clip_instances:
			instance.clip = project.get_clip(instance.clip_id)
		
		# Set project reference for channel linking (BEFORE adding to array)
		track.set_project_ref(project)
		
		# Append directly to avoid triggering track_added signal during load
		# (signals will be connected when project is activated in Editor)
		project.tracks.append(track)

	_relink_folder_buses(project)
	return project


## Re-bind folder/group tracks to their mixer buses after load.
static func _relink_folder_buses(project: Project) -> void:
	for track in project.tracks:
		if track == null or track.type != Track.TrackType.FOLDER:
			continue
		track.set_project_ref(project)
		var ch := track.get_linked_channel()
		print("[Project] Loaded folder '%s' (id %d) bus=%s default_channel_id=%d" % [
			track.name, track.id, ("%d" % ch.id) if ch else "none", track.default_channel_id
		])


# ============================================================================
# START POSITION
# ============================================================================

func set_start_position(ticks: int) -> void:
	"""Set the playback start position in ticks."""
	start_position_ticks = ticks
	start_position_changed.emit(ticks)

# ============================================================================
# HELPERS
# ============================================================================

func _generate_random_color() -> Color:
	"""Generate a pleasant random color for new channels/tracks."""
	var hue = randf()
	var saturation = randf_range(0.5, 0.8)
	var value = randf_range(0.3, 0.6)
	return Color.from_hsv(hue, saturation, value)
