class_name Project extends RefCounted

static var logger := Log.make("Project")

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
signal marker_added(marker: SongMarker)
signal marker_removed(marker: SongMarker)
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
var markers: Array[SongMarker] = []

var next_marker_id: int = 1

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
var next_note_id: int = 1     # Counter for assigning unique MIDI note IDs

# Project metadata
var project_name: String = "Untitled"
var created_date: int = 0  # Unix timestamp
var modified_date: int = 0

# Connection state
var _connection_state: ConnectionState = ConnectionState.DISCONNECTED

## Depth of nested place_track / apply_track_layout batches (UI skips per-track rebuilds).
var _track_layout_batch: int = 0

## True while nest_channel/unnest_channel is syncing the paired track (skip re-entrant nest).
var _channel_nest_syncing: bool = false

## True while place_track is syncing the paired channel (skip re-entrant place).
var _track_nest_syncing: bool = false


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
	master.set_project(self)
	channels.append(master)


# ============================================================================
# AUDIO ENGINE SYNC
# ============================================================================

func connect_to_engine() -> void:
	"""Connect project and all data to audio engine."""
	if _connection_state != ConnectionState.DISCONNECTED:
		logger.info("[Project] Already connected or connecting (state: %d)" % _connection_state)
		return

	# Set state to CONNECTING immediately (before any async operations)
	_connection_state = ConnectionState.CONNECTING
	connection_state_changed.emit(ConnectionState.CONNECTING)
	logger.info("[Project] Connecting to audio engine...")

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


func _on_engine_confirmed_connected() -> void:
	"""Called when engine confirms it's ready (after receiving /status/connected)."""
	if _connection_state == ConnectionState.CONNECTED:
		# Heartbeats keep flowing across a fast engine restart, so Godot never disconnects
		# and skips recreating master — mix then has nowhere to go.
		logger.info("[Project] Engine session restarted, resyncing project...")
		_mark_engine_data_unsynced()
		_connection_state = ConnectionState.DISCONNECTED
		connection_state_changed.emit(ConnectionState.DISCONNECTED)
		connect_to_engine()
		return

	logger.info("[Project] Engine confirmed connection, syncing project data...")
	
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

	logger.info("[Project] Connected to audio engine")


func _on_engine_disconnected() -> void:
	"""Called when engine connection is lost (heartbeat timeout)."""
	if _connection_state == ConnectionState.DISCONNECTED:
		return  # Already disconnected
	
	logger.warn("[Project] Engine connection lost!")
	_mark_engine_data_unsynced()
	_connection_state = ConnectionState.DISCONNECTED
	connection_state_changed.emit(ConnectionState.DISCONNECTED)


## Drop local engine-sync flags so the next handshake recreates channels (including master).
func _mark_engine_data_unsynced() -> void:
	for channel in channels:
		channel.disconnect_from_engine()
	for track in tracks:
		track.disconnect_from_engine()


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
	logger.info("[Project] Tracked clip request", clip_id, "->", req_id)


func _clear_clip_request_by_req(req_id: String) -> void:
	if req_id.is_empty():
		return
	if _request_clip_lookup.has(req_id):
		var clip_id: String = _request_clip_lookup[req_id]
		logger.info("[Project] Clearing clip request", clip_id, "for", req_id)
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
	return Engine.get_main_loop() as SceneTree


func _on_clip_load_state_received(args: Array, address: String) -> void:
	if address.is_empty():
		return
	var parts := address.split("/")
	if parts.size() < 3:
		return
	var clip_id := parts[2]
	logger.info("[Project] load_state", args, "from", address)
	var clip := get_clip(clip_id)
	if clip == null:
		logger.warn("[Project] Received load_state for unknown clip: ", clip_id)
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
	"""Handle OSC /audiofile/decode/ready: decoded metadata and the waveform cache key.

	Waveform levels follow as /audiofile/waveform/level events and render progressively.
	OSC args: [req_id, cache_key, channels, frames, sample_rate, duration_s, sample_count?]
	"""
	if args.is_empty():
		return
	var req_id := str(args[0])
	var pyramid := _waveform_for_req(req_id)
	if pyramid == null or not pyramid.apply_decode_ready(args):
		return
	var clip := _get_clip_by_req_id(req_id)
	if clip:
		clip.update_content_length_from_metadata(tempo, ppq)


## Waveform pyramid for an AudioFileService request: the clip's, or the device's (created on demand).
func _waveform_for_req(req_id: String) -> WaveformPyramid:
	var clip := _get_clip_by_req_id(req_id)
	if clip:
		return clip.waveform
	var inst := _get_device_by_req_id(req_id)
	if inst == null:
		return null
	if inst.sample_waveform == null:
		inst.sample_waveform = WaveformPyramid.new()
	return inst.sample_waveform


func _on_audiofile_waveform_level(args: Array) -> void:
	"""Handle OSC /audiofile/waveform/level: ingest one resolution level from the cache file.

	OSC args: [req_id, level, block_size, num_blocks?, file_path?, byte_offset?, byte_len?]
	Clip levels that fail to ingest are retried with backoff.
	"""
	if args.size() < 3:
		push_error("[Project] Waveform level: Insufficient arguments (got %d, need 3)" % args.size())
		return
	var req_id := str(args[0])
	var pyramid := _waveform_for_req(req_id)
	if pyramid == null:
		return
	if pyramid.apply_waveform_level(args):
		return
	if _get_clip_by_req_id(req_id):
		var num_blocks := int(args[3]) if args.size() >= 4 else 0
		var file_path := str(args[4]) if args.size() >= 5 else ""
		_schedule_waveform_retry(req_id, int(args[1]), int(args[2]), num_blocks, file_path)


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

	# Retry ingestion
	if clip.waveform.retry_waveform_level(level, block_size, num_blocks):
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
	# Always unregister listeners, even if the connection state already
	# reads DISCONNECTED (e.g. the engine dropped the connection before the
	# project was closed). Otherwise a closed project keeps listening for
	# engine reconnection and OSC traffic, and comes back to life when the
	# engine reconnects. This part must be idempotent.
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

	var was_connected := _connection_state != ConnectionState.DISCONNECTED
	if was_connected:
		logger.info("[Project] Disconnecting from audio engine...")
		# Clear project (this clears clips, tracks, channels from engine)
		AudioEngineOSC.send("/project/clear", [])
		# Reset AudioEngineOSC connection state
		AudioEngineOSC.reset_connection()

	_connection_state = ConnectionState.DISCONNECTED
	connection_state_changed.emit(ConnectionState.DISCONNECTED)
	logger.info("[Project] Disconnected from audio engine")


func _sync_clip_to_engine(clip: Clip) -> void:
	"""Sync a clip and its MIDI notes or audio data to the audio engine."""
	if _connection_state != ConnectionState.CONNECTED:
		logger.warn("[Project] _sync_clip_to_engine called but not connected!")
		return

	# Create clip in engine
	var clip_type_str = "midi" if clip.type == Clip.ClipType.MIDI else "audio"
	logger.info("[Project] Creating %s clip in engine: %s" % [clip_type_str, clip.id])
	AudioEngineOSC.send("/clip/create", [clip.id, clip_type_str, clip.name])
	# Mark as synced locally so subsequent updates (move/resize) don't warn
	clip.mark_synced_to_engine()

	# Sync MIDI notes (if MIDI clip)
	if clip.type == Clip.ClipType.MIDI:
		logger.info("[Project] Syncing %d MIDI notes for clip: %s" % [clip.midi_notes.size(), clip.id])
		for note in clip.midi_notes:
			logger.info("[Project]   - Note %d: pitch=%d start=%d dur=%d" % [note.id, note.note, note.start_tick, note.duration_ticks])
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
			logger.info("[Project] Requesting engine-side load for clip %s (%s)" % [clip.id, clip.audio_file_path])
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
			logger.warn("[Project] Audio clip %s has no audio_file_path!" % clip.id)


# ============================================================================
# CHANNEL MANAGEMENT
# ============================================================================
## Add an existing channel to the project. `paired_track` (about to be linked to it) may share its name.
func add_channel(channel: Channel, paired_track: Track = null) -> void:
	channel.set_project(self)
	# Re-add path (undo/redo): the name may have been taken since the channel was removed.
	var final_name := unique_name(channel.name, paired_track, channel, "Channel")
	if final_name != channel.name:
		logger.info("[Project] Re-added channel %d \"%s\" as \"%s\" (name taken)" % [channel.id, channel.name, final_name])
		channel.set_name(final_name)
	_attach_channel(channel)


## Add `channel` as-is (its name was already made unique by the caller).
func _attach_channel(channel: Channel) -> void:
	channel.set_project(self)
	channels.append(channel)
	channel_added.emit(channel)

	# Auto-connect if project is connected
	if _connection_state == ConnectionState.CONNECTED:
		channel.connect_to_engine()


func create_channel(channel_name: String = "Channel", channel_type: Channel.ChannelType = Channel.ChannelType.BUS) -> Channel:
	"""Create a new channel with unique ID and add to project."""
	return _new_channel(unique_name(channel_name, null, null, "Channel"), channel_type)


## Create and add a channel named exactly `channel_name` (the caller made it unique).
func _new_channel(channel_name: String, channel_type: Channel.ChannelType) -> Channel:
	var channel = Channel.new(next_channel_id)
	next_channel_id += 1

	channel.name = channel_name
	channel.channel_type = channel_type
	channel.output_channel_id = 1  # Route to master (ID 1) by default
	channel.color = _generate_random_color()
	_attach_channel(channel)

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


## Every track and channel name except `exclude_track` / `exclude_channel` (and each one's linked partner).
func names_in_use(exclude_track: Track = null, exclude_channel: Channel = null) -> PackedStringArray:
	return ProjectNaming.names_in_use(self, exclude_track, exclude_channel)


## `desired`, or `desired N` if the name is taken or reserved (see ProjectNaming).
func unique_name(desired: String, exclude_track: Track = null, exclude_channel: Channel = null, fallback: String = "Track") -> String:
	return ProjectNaming.unique_name(self, desired, exclude_track, exclude_channel, fallback)


## The track or channel called `name` (case-insensitive), as {track, channel}. Either may be null.
func find_by_name(name: String) -> Dictionary:
	return ProjectNaming.find_by_name(self, name)


## Rename duplicate or reserved track/channel names (run after loading).
func dedupe_names() -> void:
	ProjectNaming.dedupe_names(self)


## Find a device instance by id across all mixer channels.
func find_device_instance(instance_id: String) -> DeviceInstance:
	if instance_id.is_empty():
		return null
	for channel in channels:
		var found := channel.find_device_by_id(instance_id)
		if found:
			return found
	return null


func remove_channel(channel_id: int) -> bool:
	"""Remove a channel from the project. Returns true if successful."""
	var channel = get_channel_by_id(channel_id)
	if not channel:
		return false
	
	# Prevent removing the master channel
	if channel.is_master:
		logger.warn("[Project] Cannot remove master channel")
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
		
		logger.info("[Project] Track '%s' rerouted to Master (was using removed channel %d)" % [track.name, channel_id])
	
	# Reroute any channels that were routing to this channel to the master channel
	for ch in channels:
		if ch.output_channel_id == channel_id:
			ch.set_route(1)  # Route to master (ID 1)
			logger.info("[Project] Channel '%s' rerouted to Master (was routing to removed channel %d)" % [ch.name, channel_id])
		if ch.parent_channel_id == channel_id:
			ch.parent_channel_id = -1
			ch.notify_hierarchy_changed()

	# Drop this channel from its mixer's child list so the parent fold-out updates.
	if channel.parent_channel_id >= 0:
		var parent := get_channel_by_id(channel.parent_channel_id)
		if parent:
			parent.child_channel_ids.erase(channel_id)
			parent.notify_hierarchy_changed()
		channel.parent_channel_id = -1
	
	# Disconnect from engine if connected
	if _connection_state == ConnectionState.CONNECTED and channel.is_engine_connected():
		channel.disconnect_from_engine()
		# Tell engine to remove the channel
		AudioEngineOSC.send("/channel/%d/remove" % channel_id, [])
	
	# Remove from channels array
	var index = channels.find(channel)
	if index >= 0:
		channels.remove_at(index)
	channel.set_project(null)
	
	# Emit signal before cleanup
	channel_removed.emit(channel)
	
	logger.info("[Project] Channel removed: %s (ID: %d)" % [channel.name, channel_id])
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

	# Re-add path (undo/redo): the name may have been taken since the track was removed.
	# The setter renames a name-synced linked channel to the same name.
	var final_name := unique_name(track.name, track)
	if final_name != track.name:
		logger.info("[Project] Re-added track %d \"%s\" as \"%s\" (name taken)" % [track.id, track.name, final_name])
		track.name = final_name

	tracks.append(track)
	track_added.emit(track)

	# Auto-connect if project is connected
	if _connection_state == ConnectionState.CONNECTED:
		track.connect_to_engine()


func create_track(track_name: String = "Track") -> Track:
	"""Create a new track with unique ID and add to project."""
	var track = Track.new(next_track_id)
	next_track_id += 1

	track.name = unique_name(track_name)
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
	
	# Recursively remove children first (folders, groups, or any parent with kids)
	var children_to_remove: Array[int] = track.child_track_ids.duplicate()
	if children_to_remove.is_empty():
		for child in get_track_children(track):
			children_to_remove.append(child.id)
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
	if _connection_state == ConnectionState.CONNECTED and track.is_engine_connected():
		track.disconnect_from_engine()
	
	# Remove from tracks array
	var index = tracks.find(track)
	if index >= 0:
		tracks.remove_at(index)
	
	# Emit signal before cleanup
	track_removed.emit(track)
	
	logger.info("[Project] Track removed: %s (ID: %d)" % [track.name, track_id])
	return true


func get_track_children(track: Track) -> Array[Track]:
	"""Get direct children of a track (not recursive)."""
	if track == null:
		return []
	return _sorted_track_siblings(track.id)


func get_visual_track_list() -> Array[Track]:
	"""Build a flat list of tracks in visual order from the hierarchy."""
	var result: Array[Track] = []
	for root in _sorted_track_siblings(-1):
		_add_track_and_descendants_to_list(root, result)
	return result


## Tracks under `parent_id` (any negative id = root) sorted by `order`.
func _sorted_track_siblings(parent_id: int) -> Array[Track]:
	var siblings: Array[Track] = []
	for t in tracks:
		if t.parent_track_id == parent_id or (parent_id < 0 and t.parent_track_id < 0):
			siblings.append(t)
	siblings.sort_custom(func(a, b): return a.order < b.order)
	return siblings


func _add_track_and_descendants_to_list(track: Track, result: Array[Track]) -> void:
	"""Recursively add a track and all its descendants to a list."""
	result.append(track)
	for child in get_track_children(track):
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


## Next unused display name among pooled clips (`Bass`, `Bass 2`, `Bass 3`, …).
func unique_clip_name(desired: String) -> String:
	var existing: PackedStringArray = PackedStringArray()
	for c in clips.values():
		if c is Clip:
			existing.append(c.name)
	return DeviceNaming.unique_in(existing, Clip.uniqueness_base(desired), "Clip")


func add_clip(clip: Clip) -> void:
	"""Add an existing clip to the pool."""
	if clip.id.is_empty():
		push_error("[Project] Cannot add clip with empty ID")
		return

	if clips.has(clip.id):
		push_warning("[Project] Clip with ID %s already exists, replacing" % clip.id)

	clips[clip.id] = clip
	logger.info("[Project] Added clip to pool: %s (total clips: %d)" % [clip.id, clips.size()])

	# Sync to engine if connected
	if _connection_state == ConnectionState.CONNECTED:
		_sync_clip_to_engine(clip)

	clip_added.emit(clip)


## Hand out the next project-wide MIDI note ID.
func allocate_note_id() -> int:
	var note_id := next_note_id
	next_note_id += 1
	return note_id


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
	return _create_track_with_channel(track_name, Track.TrackType.INSTRUMENT, Channel.ChannelType.INSTRUMENT)


# Create audio track with corresponding channel
func create_audio_track(track_name: String = "Audio") -> Dictionary:
	"""Create a track + channel pair for audio."""
	return _create_track_with_channel(track_name, Track.TrackType.AUDIO, Channel.ChannelType.AUDIO)


## Track of `track_type` paired with a new channel of `channel_type`. Returns {track, channel}.
func _create_track_with_channel(
	track_name: String,
	track_type: Track.TrackType,
	channel_type: Channel.ChannelType
) -> Dictionary:
	# One name for the pair, reserved before either exists so they don't collide with each other.
	var pair_name := unique_name(track_name)
	var track := create_track(pair_name)
	track.type = track_type

	var channel := _new_channel(pair_name, channel_type)

	track.default_channel_id = channel.id  # Setter auto-reconnects if needed

	# Connect track to engine now that it has a valid channel
	if _connection_state == ConnectionState.CONNECTED:
		track.connect_to_engine()

	return {"track": track, "channel": channel}


# Create bus channel (no track)
func create_bus_channel(bus_name: String = "Bus") -> Channel:
	"""Create a bus channel (routing only, no track)."""
	return create_channel(bus_name, Channel.ChannelType.BUS)


## Create a Group track: timeline parent paired with a left-pane GROUP mix channel.
func create_group_track(group_name: String = "Group") -> Dictionary:
	var track = Track.new(next_track_id)
	next_track_id += 1
	track.type = Track.TrackType.GROUP
	track.height = 60
	track.set_project_ref(self)

	var pair_name := unique_name(group_name)
	var channel := _new_channel(pair_name, Channel.ChannelType.GROUP)
	track.pair_mixer_channel(channel)
	track.name = pair_name
	add_track(track)
	logger.info("[Project] Group '%s' (track %d) channel=%d" % [track.name, track.id, channel.id])
	return {"track": track, "channel": channel}


## Create a folder track. `with_channel` true makes it a Folder Bus (dedicated right-pane bus).
func create_folder_track(folder_name: String = "Folder", with_channel: bool = false) -> Dictionary:
	var track = Track.new(next_track_id)
	next_track_id += 1
	track.type = Track.TrackType.FOLDER
	track.height = 60
	track.set_project_ref(self)

	var pair_name := unique_name(folder_name)
	var channel = null
	if with_channel:
		channel = _new_channel(pair_name, Channel.ChannelType.BUS)
		track.pair_mixer_channel(channel)
	else:
		track.color_by_channel = false
		track.name_by_channel = false

	track.name = pair_name
	add_track(track)
	logger.info("[Project] %s '%s' (track %d) bus=%s" % [
		"Folder Bus" if with_channel else "Folder",
		track.name,
		track.id,
		("%d" % channel.id) if channel else "none"
	])
	return {"track": track, "channel": channel}


## Mixer bus of the nearest ancestor Folder Bus, or null if none.
func get_enclosing_folder_bus(track: Track) -> Channel:
	var folder := _ancestor_where(track, func(t: Track) -> bool: return t.is_folder_bus())
	return folder.get_linked_channel() if folder else null


## Mixer channel of the nearest ancestor Group, or null if none.
func get_enclosing_group_channel(track: Track) -> Channel:
	var group := _ancestor_where(track, func(t: Track) -> bool: return t.is_group())
	return group.get_linked_channel() if group else null


## Nearest ancestor of `track` (not the track itself) for which `predicate` is true, or null.
func _ancestor_where(track: Track, predicate: Callable) -> Track:
	if track == null:
		return null
	var parent := get_track_by_id(track.parent_track_id) if track.parent_track_id >= 0 else null
	while parent:
		if predicate.call(parent):
			return parent
		parent = get_track_by_id(parent.parent_track_id) if parent.parent_track_id >= 0 else null
	return null


## Mixer channel this track owns (instrument/audio strip, group, or folder bus).
func get_track_mixer_channel(track: Track) -> Channel:
	if track == null or track.default_channel_id < 0:
		return null
	return get_channel_by_id(track.default_channel_id)


## Track paired to this mixer channel via default_channel_id, or null.
func get_channel_paired_track(ch: Channel) -> Track:
	if ch == null:
		return null
	for track in tracks:
		if track.default_channel_id == ch.id:
			return track
	return null


## Route this track's mixer channel: locked group parent, else Folder Bus, else Master.
func sync_track_hierarchy_routing(track: Track) -> void:
	var ch := get_track_mixer_channel(track)
	if ch == null or ch.is_master:
		return
	if ch.parent_channel_id >= 0:
		if ch.output_channel_id != ch.parent_channel_id:
			ch.set_route(ch.parent_channel_id)
		return
	var group_ch := get_enclosing_group_channel(track)
	if group_ch:
		if ch.output_channel_id != group_ch.id:
			ch.set_route(group_ch.id)
		return
	var bus := get_enclosing_folder_bus(track)
	var target_id := bus.id if bus else 1
	if ch.id == target_id:
		return
	if ch.output_channel_id != target_id:
		ch.set_route(target_id)


## Route a parent and every descendant according to group / folder-bus ancestry.
func sync_subtree_hierarchy_routing(track: Track) -> void:
	if track == null:
		return
	sync_track_hierarchy_routing(track)
	for child in get_track_children(track):
		sync_subtree_hierarchy_routing(child)


## Pair a folder with a bus (making it a Folder Bus) and route descendants to that bus.
func link_folder_to_bus(track: Track, bus: Channel) -> void:
	if track == null or bus == null or track.type != Track.TrackType.FOLDER:
		return
	track.color_by_channel = true
	track.name_by_channel = true
	track.pair_mixer_channel(bus)
	sync_subtree_hierarchy_routing(track)


## Turn a Folder Bus back into a channel-less folder and re-route descendants.
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
	# Excluding the folder lets the new bus share its name; linking makes them one pair.
	var bus := _new_channel(unique_name(track.name, track, null, "Bus"), Channel.ChannelType.BUS)
	bus.set_color(track.get_color())
	link_folder_to_bus(track, bus)
	return bus


## Add a track as the last child of a folder or group.
func add_track_to_folder(track_id: int, folder_id: int) -> bool:
	var track = get_track_by_id(track_id)
	var folder = get_track_by_id(folder_id)
	if not track or not folder or not folder.can_contain_tracks():
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
		if new_parent == null or not new_parent.can_contain_tracks():
			return false

	var mixer := get_track_mixer_channel(track)
	if mixer and mixer.is_aux_return():
		var source_ch := get_channel_by_id(mixer.parent_channel_id)
		var source_track := get_channel_paired_track(source_ch) if source_ch else null
		if source_track and new_parent_id != source_track.id:
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

	_sync_track_child_ids(new_parent_id)
	if old_parent_id != new_parent_id:
		_renumber_siblings(old_parent_id)
		_sync_track_child_ids(old_parent_id)
		if not _track_nest_syncing:
			_sync_channel_nest_for_track_move(track, old_parent_id, new_parent_id, after_sibling)
		sync_subtree_hierarchy_routing(track)
	elif not _track_nest_syncing:
		_sync_channel_order_for_track(track, new_parent_id, after_sibling)

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
	var restored_channel_fields := false
	for track in tracks:
		if not layout.has(track.id):
			continue
		var entry: Dictionary = layout[track.id]
		var ch := get_track_mixer_channel(track)
		if ch == null:
			continue
		if entry.has("channel_parent_id"):
			ch.parent_channel_id = int(entry["channel_parent_id"])
			restored_channel_fields = true
		if entry.has("channel_child_ids"):
			var ch_child_ids: Array[int] = []
			ch_child_ids.assign(entry["channel_child_ids"])
			ch.child_channel_ids = ch_child_ids
			restored_channel_fields = true
		if entry.has("output_channel_id"):
			var out_id: int = int(entry["output_channel_id"])
			if out_id >= 0 and ch.output_channel_id != out_id:
				ch.set_route(out_id)
			restored_channel_fields = true
		ch.notify_hierarchy_changed()
	if not restored_channel_fields:
		for track in tracks:
			sync_track_hierarchy_routing(track)
	end_track_layout_batch()


## True if `maybe_descendant_id` is `root` or nested under it.
func track_is_in_subtree(maybe_descendant_id: int, root: Track) -> bool:
	if root == null:
		return false
	return _id_in_subtree(maybe_descendant_id, root.id, func(id: int) -> int:
		var node := get_track_by_id(id)
		return node.parent_track_id if node else -1
	)


## Walk parents from `id` via `parent_of(id) -> parent id (-1 at the root)`; true on reaching `root_id`.
## Stops on a cycle.
static func _id_in_subtree(id: int, root_id: int, parent_of: Callable) -> bool:
	var visited: Dictionary = {}
	var walk_id := id
	while walk_id >= 0:
		if walk_id == root_id:
			return true
		if visited.has(walk_id):
			return false
		visited[walk_id] = true
		walk_id = int(parent_of.call(walk_id))
	return false


## True if `track` already sits after `after_sibling` under `new_parent_id`.
func _track_already_placed(track: Track, new_parent_id: int, after_sibling: Track) -> bool:
	if track.parent_track_id != new_parent_id:
		return false
	var previous: Track = null
	for sibling in _sorted_track_siblings(new_parent_id):
		if sibling == track:
			return previous == after_sibling
		previous = sibling
	return false


## Keep a parent's child_track_ids in sibling order.
func _sync_track_child_ids(parent_id: int) -> void:
	if parent_id < 0:
		return
	var parent := get_track_by_id(parent_id)
	if parent == null or not parent.can_contain_tracks():
		return
	var ids: Array[int] = []
	for child in get_track_children(parent):
		ids.append(child.id)
	parent.child_track_ids = ids


## True when `child` may nest under mixer `parent` (not bus/master, no cycles).
func can_nest_channel(child: Channel, parent: Channel, after_sibling: Channel = null) -> bool:
	if child == null or parent == null:
		return false
	if child.is_master or parent.is_master:
		return false
	if child.is_bus or parent.is_bus:
		return false
	if child.id == parent.id:
		return false
	if child.is_aux_return() and child.parent_channel_id >= 0 and parent.id != child.parent_channel_id:
		return false
	if channel_is_in_subtree(parent.id, child):
		return false
	if after_sibling != null and after_sibling.parent_channel_id != parent.id and after_sibling != child:
		return false
	return true


## Nest `child` under `parent`, after `after_sibling` (null = first). Locks route to parent.
func nest_channel(child: Channel, parent: Channel, after_sibling: Channel = null) -> bool:
	if not can_nest_channel(child, parent, after_sibling):
		return false

	var old_parent_id := child.parent_channel_id
	if old_parent_id >= 0 and old_parent_id != parent.id:
		var old_parent := get_channel_by_id(old_parent_id)
		if old_parent:
			old_parent.child_channel_ids.erase(child.id)
			old_parent.notify_hierarchy_changed()

	child.parent_channel_id = parent.id
	_insert_child_channel_id(parent, child.id, after_sibling)
	if child.output_channel_id != parent.id:
		child.set_route(parent.id)
	child.notify_hierarchy_changed()
	parent.notify_hierarchy_changed()

	if not _channel_nest_syncing:
		var child_track := get_channel_paired_track(child)
		var parent_track := get_channel_paired_track(parent)
		if child_track and parent_track:
			var after_track := get_channel_paired_track(after_sibling) if after_sibling else null
			_track_nest_syncing = true
			place_track(child_track, parent_track.id, after_track)
			_track_nest_syncing = false
	return true


## Un-nest `child` to mixer root and route to enclosing Folder Bus or Master.
func unnest_channel(child: Channel) -> bool:
	if child == null or child.parent_channel_id < 0:
		return false
	var old_parent := get_channel_by_id(child.parent_channel_id)
	child.parent_channel_id = -1
	if old_parent:
		old_parent.child_channel_ids.erase(child.id)
		old_parent.notify_hierarchy_changed()

	var paired := get_channel_paired_track(child)
	var bus := get_enclosing_folder_bus(paired) if paired else null
	var target_id := bus.id if bus else 1
	if child.output_channel_id != target_id:
		child.set_route(target_id)
	child.notify_hierarchy_changed()

	if not _channel_nest_syncing and paired:
		var old_group_track := get_channel_paired_track(old_parent) if old_parent else null
		var new_parent_id := old_group_track.parent_track_id if old_group_track else -1
		_track_nest_syncing = true
		place_track(paired, new_parent_id, old_group_track)
		_track_nest_syncing = false
	return true


## Direct mixer children of `ch` in fold-out order.
func get_channel_children(ch: Channel) -> Array[Channel]:
	var children: Array[Channel] = []
	if ch == null:
		return children
	for child_id in ch.child_channel_ids:
		var child := get_channel_by_id(child_id)
		if child:
			children.append(child)
	return children


## True if `maybe_descendant_id` is `root` or nested under it in the channel tree.
func channel_is_in_subtree(maybe_descendant_id: int, root: Channel) -> bool:
	if root == null:
		return false
	return _id_in_subtree(maybe_descendant_id, root.id, func(id: int) -> int:
		var node := get_channel_by_id(id)
		return node.parent_channel_id if node else -1
	)


## Insert `child_id` into `parent.child_channel_ids` after `after_sibling` (null = first).
func _insert_child_channel_id(parent: Channel, child_id: int, after_sibling: Channel) -> void:
	parent.child_channel_ids.erase(child_id)
	if after_sibling == null:
		parent.child_channel_ids.insert(0, child_id)
		return
	var idx := parent.child_channel_ids.find(after_sibling.id)
	if idx >= 0:
		parent.child_channel_ids.insert(idx + 1, child_id)
	else:
		parent.child_channel_ids.append(child_id)


## When a track moves into/out of a mix parent, nest or unnest its mixer channel.
func _sync_channel_nest_for_track_move(
	track: Track,
	_old_parent_id: int,
	new_parent_id: int,
	after_sibling: Track
) -> void:
	var ch := get_track_mixer_channel(track)
	if ch == null:
		return
	_channel_nest_syncing = true
	var new_parent := get_track_by_id(new_parent_id)
	var parent_ch := get_track_mixer_channel(new_parent) if new_parent else null
	var after_ch := get_track_mixer_channel(after_sibling) if after_sibling else null
	if parent_ch != null and can_nest_channel(ch, parent_ch, after_ch):
		nest_channel(ch, parent_ch, after_ch)
	elif ch.parent_channel_id >= 0 and not ch.is_aux_return():
		unnest_channel(ch)
	_channel_nest_syncing = false


## Keep mixer sibling order in sync when reordering under the same mix parent.
func _sync_channel_order_for_track(track: Track, new_parent_id: int, after_sibling: Track) -> void:
	var parent_track := get_track_by_id(new_parent_id)
	var parent_ch := get_track_mixer_channel(parent_track)
	var child_ch := get_track_mixer_channel(track)
	if parent_ch == null or child_ch == null:
		return
	if child_ch.parent_channel_id != parent_ch.id:
		return
	var after_ch := get_track_mixer_channel(after_sibling) if after_sibling else null
	_insert_child_channel_id(parent_ch, child_ch.id, after_ch)
	parent_ch.notify_hierarchy_changed()


## Rebuild child_channel_ids from parent_channel_id when a save omitted the array.
func _rebuild_channel_child_ids_from_parents() -> void:
	var children_by_parent: Dictionary = {}
	for ch in channels:
		if ch.parent_channel_id < 0:
			continue
		if not children_by_parent.has(ch.parent_channel_id):
			children_by_parent[ch.parent_channel_id] = []
		children_by_parent[ch.parent_channel_id].append(ch.id)
	for parent_id in children_by_parent:
		var parent := get_channel_by_id(int(parent_id))
		if parent == null:
			continue
		if not parent.child_channel_ids.is_empty():
			continue
		var ids: Array[int] = []
		ids.assign(children_by_parent[parent_id])
		parent.child_channel_ids = ids


func _renumber_siblings(parent_id: int) -> void:
	"""Renumber all tracks with the same parent to have sequential order."""
	var siblings := _sorted_track_siblings(parent_id)
	for i in range(siblings.size()):
		siblings[i].order = i


# ============================================================================
# SERIALIZATION
# ============================================================================

# Serialize to JSON
func to_json() -> Dictionary:
	# Serialize clip pool
	var clips_array = []
	logger.info("[Project] Serializing %d clips from pool: %s" % [clips.size(), str(clips.keys())])
	for clip_id in clips.keys():
		logger.info("[Project] Serializing clip: %s" % clip_id)
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
		"next_note_id": next_note_id,
		"next_marker_id": next_marker_id,
		"markers": markers.map(func(m): return m.to_json()),
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
	project.next_channel_id = data.get("next_channel_id", 2)
	project.next_track_id = data.get("next_track_id", 0)
	project.next_note_id = data.get("next_note_id", 1)
	project.next_marker_id = data.get("next_marker_id", 1)

	project.markers.clear()
	for marker_data in data.get("markers", []):
		project.markers.append(SongMarker.from_json(marker_data))

	# Load clip pool (must load before tracks, since tracks reference clips)
	project.clips.clear()
	for clip_data in data.get("clips", []):
		var clip = Clip.from_json(clip_data)
		project.clips[clip.id] = clip

	# Clear default master and load channels
	project.channels.clear()
	for channel_data in data.get("channels", []):
		var channel := Channel.from_json(channel_data)
		channel.set_project(project)
		project.channels.append(channel)

	# Guard against a stale/missing next_channel_id counter: never hand out
	# an ID that's already in use (e.g. from an older save with no counter).
	for existing_channel in project.channels:
		if existing_channel and existing_channel.id >= project.next_channel_id:
			project.next_channel_id = existing_channel.id + 1

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
	project._rebuild_channel_child_ids_from_parents()
	# Before ensure_all, so pad returns re-syncing their names see an already unique namespace.
	project.dedupe_names()
	AuxReturnSync.ensure_all(project)
	return project


## Re-bind folder and group tracks to their mixer channels after load.
static func _relink_folder_buses(project: Project) -> void:
	for track in project.tracks:
		if track == null:
			continue
		if track.type != Track.TrackType.FOLDER and track.type != Track.TrackType.GROUP:
			continue
		track.set_project_ref(project)
		var ch := track.get_linked_channel()
		logger.info("[Project] Loaded %s '%s' (id %d) channel=%s default_channel_id=%d" % [
			"Group" if track.is_group() else "folder",
			track.name,
			track.id,
			("%d" % ch.id) if ch else "none",
			track.default_channel_id
		])


# ============================================================================
# START POSITION
# ============================================================================

func set_start_position(ticks: int) -> void:
	"""Set the playback start position in ticks."""
	start_position_ticks = ticks
	start_position_changed.emit(ticks)


# ============================================================================
# MARKERS
# ============================================================================

## Add a marker to the project and emit marker_added.
func add_marker(marker: SongMarker) -> void:
	if marker == null or markers.has(marker):
		return
	markers.append(marker)
	marker_added.emit(marker)


## Remove a marker from the project and emit marker_removed.
func remove_marker(marker: SongMarker) -> void:
	if marker == null:
		return
	var idx := markers.find(marker)
	if idx < 0:
		return
	markers.remove_at(idx)
	marker_removed.emit(marker)


## Create a new marker at the given tick range with a random color.
func create_marker(start_ticks: int, duration_ticks: int, marker_name: String = "Marker") -> SongMarker:
	var marker := SongMarker.new()
	marker.id = next_marker_id
	next_marker_id += 1
	marker.name = marker_name
	marker.start_ticks = maxi(0, start_ticks)
	marker.duration_ticks = maxi(get_ticks_per_beat(), duration_ticks)
	marker.color = _generate_random_color()
	return marker


func get_ticks_per_beat() -> int:
	return GridHelper.beat_ticks(ppq, time_denominator)

# ============================================================================
# HELPERS
# ============================================================================

func _generate_random_color() -> Color:
	"""Generate a pleasant random color for new channels/tracks."""
	var hue = randf()
	var saturation = randf_range(0.5, 0.8)
	var value = randf_range(0.3, 0.6)
	return Color.from_hsv(hue, saturation, value)
