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
		return

	print("[Project] Connecting to audio engine...")
	
	# Set state to CONNECTING
	_connection_state = ConnectionState.CONNECTING
	connection_state_changed.emit(ConnectionState.CONNECTING)

	# Listen for engine connection confirmation
	if not AudioEngineOSC.engine_connected.is_connected(_on_engine_confirmed_connected):
		AudioEngineOSC.engine_connected.connect(_on_engine_confirmed_connected)
	
	# Listen for engine disconnection
	if not AudioEngineOSC.engine_disconnected.is_connected(_on_engine_disconnected):
		AudioEngineOSC.engine_disconnected.connect(_on_engine_disconnected)

	# Send project initialization (engine will respond with /status/connected)
	AudioEngineOSC.send("/project/init", [tempo, time_numerator, time_denominator, ppq, sample_rate])


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
			# Send the audio file PATH instead of the massive blob
			# Engine will load it directly using its own audio loader
			print("[Project] Syncing audio clip %s to engine: %s (%s Hz, %d channels)" % [
				clip.id, clip.audio_file_path, clip.audio_sample_rate, clip.audio_channels
			])
			AudioEngineOSC.send("/clip/%s/load_audio_file" % clip.id, [
				clip.audio_file_path,
				clip.audio_sample_rate,
				clip.audio_channels
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
		# Load audio file
		var load_result = AudioFileLoader.load_audio_file(asset.path)
		if load_result["success"]:
			clip.audio_samples = load_result["samples"]
			clip.audio_sample_rate = load_result["sample_rate"]
			clip.audio_channels = load_result["channels"]

			# Calculate content length from audio duration
			var sample_count = clip.audio_samples.size() / clip.audio_channels
			var duration_seconds = float(sample_count) / float(clip.audio_sample_rate)
			var beats = duration_seconds * (tempo / 60.0)  # Use actual project tempo
			clip.content_length_ticks = int(beats * ppq)

			# Precompute waveforms for efficient rendering
			clip.precompute_waveforms()

			print("[Project] Audio clip loaded: %s (%d samples, %d Hz, %d channels, %d ticks)" % [
				asset.get_display_name(),
				sample_count,
				clip.audio_sample_rate,
				clip.audio_channels,
				clip.content_length_ticks
			])
		else:
			print("[Project] Failed to load audio: %s" % load_result.get("error", "Unknown error"))
			clip.content_length_ticks = ppq * 4  # Fallback to 4 beats
	else:
		# TODO: Load MIDI notes from asset.path when MIDI parser is available
		clip.content_length_ticks = ppq * 4  # Default 4 beats

	# Add clip to pool AFTER all data is loaded (so engine sync works correctly)
	add_clip(clip)

	return clip


func remove_clip(clip_id: String) -> bool:
	"""Remove clip from pool. Returns true if clip was found and removed."""
	if not clips.has(clip_id):
		return false

	# TODO: Check if any instances reference this clip and warn/prevent deletion
	# For now, just remove it

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

	return {"track": track, "channel": channel}


# Create audio track with corresponding channel
func create_audio_track(track_name: String = "Audio") -> Dictionary:
	"""Create a track + channel pair for audio."""
	var track = create_track(track_name)
	track.type = Track.TrackType.AUDIO

	var channel = create_channel(track_name, Channel.ChannelType.AUDIO)

	track.default_channel_id = channel.id  # Setter auto-reconnects if needed

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
