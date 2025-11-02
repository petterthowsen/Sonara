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


func _get_scene_tree() -> SceneTree:
	var loop := Engine.get_main_loop()
	return loop as SceneTree if loop is SceneTree else null


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
	if args.size() < 6:
		return
	var req_id := str(args[0])
	var clip := _get_clip_by_req_id(req_id)
	if clip == null:
		print("[Project] decode_ready for unknown req", req_id, "args", args)
		return

	var cache_key: String = str(args[1])
	var decoded_channels: int = int(args[2])
	var frames: int = int(args[3])
	var decoded_sample_rate: int = int(args[4])
	var duration_s: float = float(args[5])
	print("[Project] decode_ready clip", clip.id, "frames", frames, "cache", cache_key)

	clip.waveform_cache_key = cache_key
	clip.set_audio_metadata(decoded_sample_rate, decoded_channels, frames, duration_s)
	clip.update_content_length_from_metadata(tempo, ppq)


func _on_audiofile_waveform_level(args: Array) -> void:
	if args.size() < 7:
		return
	var req_id := str(args[0])
	var clip := _get_clip_by_req_id(req_id)
	if clip == null:
		print("[Project] Waveform level for unknown req", req_id, "(args", args, ")")
		return

	var level := int(args[1])
	var block_size := int(args[2])
	var num_blocks := int(args[3])
	var file_path := str(args[4])
	print("[Project] waveform level", level, "for clip", clip.id, "blocks", num_blocks, "block_size", block_size)

	if clip.waveform_cache_key.is_empty():
		clip.waveform_cache_key = file_path.get_file()
	clip.set_waveform_cache(file_path, clip.waveform_cache_key)

	if not clip.ingest_waveform_level_from_cache(level, block_size, num_blocks):
		print("[Project] Ingest waveform level", level, "failed for", clip.id)
		_schedule_waveform_retry(req_id, level, block_size, num_blocks, file_path)
	else:
		print("[Project] Ingested waveform level", level, "for clip", clip.id, "(req", req_id, ")")


func _on_audiofile_progress(args: Array) -> void:
	if args.size() < 2:
		return
	var req_id := str(args[0])
	var clip := _get_clip_by_req_id(req_id)
	if clip == null:
		return
	var progress := float(args[1])
	clip.update_load_progress(progress)


func _on_audiofile_error(args: Array) -> void:
	if args.size() < 3:
		return
	var req_id := str(args[0])
	var clip := _get_clip_by_req_id(req_id)
	if clip == null:
		return
	var code := int(args[1])
	var message := str(args[2])
	clip.apply_load_state(Clip.LoadState.FAILED, req_id, "[%d] %s" % [code, message])
	_clear_clip_request_by_req(req_id)


func _schedule_waveform_retry(req_id: String, level: int, block_size: int, num_blocks: int, file_path: String, attempt: int = 1) -> void:
	var key := "%s:%d" % [req_id, level]
	var info: Dictionary = _pending_waveform_retries.get(key, {})
	var current_attempt: int = int(info.get("attempt", 0))
	if current_attempt >= 3:
		return
	var next_attempt: int = int(max(attempt, current_attempt + 1))
	_pending_waveform_retries[key] = {
		"attempt": next_attempt,
		"block_size": block_size,
		"num_blocks": num_blocks,
		"file_path": file_path
	}
	var delay: float = 0.25 * float(next_attempt)
	var scene_tree := _get_scene_tree()
	if scene_tree == null:
		return
	var timer = scene_tree.create_timer(delay)
	timer.timeout.connect(_on_waveform_retry_timeout.bind(req_id, level))


func _on_waveform_retry_timeout(req_id: String, level: int) -> void:
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
	var file_path := str(info.get("file_path", ""))
	if file_path.is_empty():
		_pending_waveform_retries.erase(key)
		return

	clip.set_waveform_cache(file_path, clip.waveform_cache_key if not clip.waveform_cache_key.is_empty() else file_path.get_file())
	if clip.ingest_waveform_level_from_cache(level, block_size, num_blocks):
		_pending_waveform_retries.erase(key)
	else:
		var attempt := int(info.get("attempt", 1))
		if attempt >= 3:
			_pending_waveform_retries.erase(key)
		else:
			_schedule_waveform_retry(req_id, level, block_size, num_blocks, file_path, attempt + 1)


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
	if track.type == Track.TrackType.FOLDER:
		for child_id in track.child_track_ids:
			var child = get_track_by_id(child_id)
			if child:
				children.append(child)
		# Sort by order
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


# Create folder track with its own bus channel
func create_group_track(group_name: String = "Group") -> Dictionary[Track, Channel]:
	"""Create a group track with a bus channel."""
	return create_folder_track(group_name, true)

# Create folder track with optional channel
func create_folder_track(folder_name: String = "Folder", with_channel: bool = false) -> Dictionary:
	"""Create a folder track with optional channel."""
	var track = create_track(folder_name)
	track.type = Track.TrackType.FOLDER

	var channel = null
	if with_channel:
		channel = create_channel(folder_name, Channel.ChannelType.BUS)
		track.default_channel_id = channel.id

		# Reconnect track to update routing (if project is connected)
		if _connection_state == ConnectionState.CONNECTED and track._is_connected:
			track.disconnect_from_engine()
			track.connect_to_engine()

	return {"track": track, "channel": channel}


# Add track to folder
func add_track_to_folder(track_id: int, folder_id: int) -> bool:
	"""Add a track to a folder track."""
	var track = get_track_by_id(track_id)
	var folder = get_track_by_id(folder_id)

	if not track or not folder:
		return false
	if folder.type != Track.TrackType.FOLDER:
		return false

	# Remove from old parent if any
	var old_parent_id = track.parent_track_id
	if old_parent_id >= 0:
		var old_parent = get_track_by_id(old_parent_id)
		if old_parent:
			old_parent.child_track_ids.erase(track_id)
			# Renumber old siblings to fill the gap
			_renumber_siblings(old_parent_id)
	elif old_parent_id < 0:
		# Was a root track, renumber root siblings
		_renumber_siblings(-1)

	# Add to new parent
	track.parent_track_id = folder_id
	if not folder.child_track_ids.has(track_id):
		folder.child_track_ids.append(track_id)
	
	# Set order to be last child of the folder
	var children = get_track_children(folder)
	track.order = children.size() - 1  # Already added, so size - 1

	return true


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

	return project


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
