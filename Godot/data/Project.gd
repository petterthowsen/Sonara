class_name Project extends RefCounted

# ============================================================================
# SIGNALS
# ============================================================================

signal track_added(track: Track)
signal channel_added(channel: Channel)
signal clip_added(clip: Clip)
signal clip_removed(clip_id: String)
signal start_position_changed(ticks: int)

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
var _is_connected: bool = false

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
	if _is_connected:
		return

	print("[Project] Connecting to audio engine...")

	# Send project initialization
	AudioEngineOSC.send("/project/init", [tempo, time_numerator, time_denominator, ppq, sample_rate])

	# Sync all clips to engine (must happen before tracks, since tracks reference clips)
	for clip_id in clips.keys():
		_sync_clip_to_engine(clips[clip_id])

	# Connect all channels
	for channel in channels:
		channel.connect_to_engine()

	# Connect all tracks (this will sync clip instances which reference the clips)
	for track in tracks:
		track.connect_to_engine()

	_is_connected = true
	print("[Project] Connected to audio engine")


func disconnect_from_engine() -> void:
	"""Disconnect project and all data from audio engine."""
	if not _is_connected:
		return

	print("[Project] Disconnecting from audio engine...")

	# Disconnect all tracks
	for track in tracks:
		track.disconnect_from_engine()

	# Disconnect all channels
	for channel in channels:
		channel.disconnect_from_engine()

	# Clear project (this clears clips, tracks, channels from engine)
	AudioEngineOSC.send("/project/clear", [])

	_is_connected = false
	print("[Project] Disconnected from audio engine")


func _sync_clip_to_engine(clip: Clip) -> void:
	"""Sync a clip and its MIDI notes or audio data to the audio engine."""
	if not _is_connected:
		return

	# Create clip in engine
	var clip_type_str = "midi" if clip.type == Clip.ClipType.MIDI else "audio"
	AudioEngineOSC.send("/clip/create", [clip.id, clip_type_str, clip.name])

	# Sync MIDI notes (if MIDI clip)
	if clip.type == Clip.ClipType.MIDI:
		for note in clip.midi_notes:
			AudioEngineOSC.send("/clip/%s/add_note" % clip.id, [
				note.id,
				note.note,
				note.start_tick,
				note.duration_ticks,
				note.velocity
			])
		# Connect to clip signals to keep engine in sync
		if not clip.midi_note_added.is_connected(_on_clip_note_added):
			clip.midi_note_added.connect(_on_clip_note_added.bind(clip))
		if not clip.midi_note_removed.is_connected(_on_clip_note_removed):
			clip.midi_note_removed.connect(_on_clip_note_removed.bind(clip))
		if not clip.midi_note_changed.is_connected(_on_clip_note_changed):
			clip.midi_note_changed.connect(_on_clip_note_changed.bind(clip))
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


func _on_clip_note_added(note: MidiNoteData, clip: Clip) -> void:
	"""Handle when a note is added to a clip - sync to engine."""
	if _is_connected:
		AudioEngineOSC.send("/clip/%s/add_note" % clip.id, [
			note.id,
			note.note,
			note.start_tick,
			note.duration_ticks,
			note.velocity
		])


func _on_clip_note_removed(note: MidiNoteData, clip: Clip) -> void:
	"""Handle when a note is removed from a clip - sync to engine."""
	if _is_connected:
		AudioEngineOSC.send("/clip/%s/remove_note" % clip.id, [note.id])


func _on_clip_note_changed(note: MidiNoteData, clip: Clip) -> void:
	"""Handle when a note is changed in a clip - sync to engine."""
	if _is_connected:
		AudioEngineOSC.send("/clip/%s/update_note" % clip.id, [
			note.id,
			note.note,
			note.start_tick,
			note.duration_ticks,
			note.velocity
		])


# ============================================================================
# CHANNEL MANAGEMENT
# ============================================================================

func add_channel(channel: Channel) -> void:
	"""Add an existing channel to the project."""
	channels.append(channel)
	channel_added.emit(channel)

	# Auto-connect if project is connected
	if _is_connected:
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
	tracks.append(track)
	track_added.emit(track)

	# Auto-connect if project is connected
	if _is_connected:
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

	# Sync to engine if connected
	if _is_connected:
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
	if _is_connected:
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

	track.default_channel_id = channel.id

	# Reconnect track to update routing (if project is connected)
	if _is_connected and track._is_connected:
		track.disconnect_from_engine()
		track.connect_to_engine()

	return {"track": track, "channel": channel}


# Create audio track with corresponding channel
func create_audio_track(track_name: String = "Audio") -> Dictionary:
	"""Create a track + channel pair for audio."""
	var track = create_track(track_name)
	track.type = Track.TrackType.AUDIO

	var channel = create_channel(track_name, Channel.ChannelType.AUDIO)

	track.default_channel_id = channel.id

	# Reconnect track to update routing (if project is connected)
	if _is_connected and track._is_connected:
		track.disconnect_from_engine()
		track.connect_to_engine()

	return {"track": track, "channel": channel}


# Create bus channel (no track)
func create_bus_channel(bus_name: String = "Bus") -> Channel:
	"""Create a bus channel (routing only, no track)."""
	return create_channel(bus_name, Channel.ChannelType.BUS)


# Create group track (folder) with optional channel
func create_group_track(group_name: String = "Group", with_channel: bool = true) -> Dictionary:
	"""Create a group track (folder) with optional channel."""
	var track = create_track(group_name)
	track.type = Track.TrackType.GROUP

	var channel = null
	if with_channel:
		channel = create_channel(group_name, Channel.ChannelType.BUS)
		track.default_channel_id = channel.id

		# Reconnect track to update routing (if project is connected)
		if _is_connected and track._is_connected:
			track.disconnect_from_engine()
			track.connect_to_engine()

	return {"track": track, "channel": channel}


# Add track to group
func add_track_to_group(track_id: int, group_id: int) -> bool:
	"""Add a track to a group track."""
	var track = get_track_by_id(track_id)
	var group = get_track_by_id(group_id)

	if not track or not group:
		return false
	if group.type != Track.TrackType.GROUP:
		return false

	# Remove from old parent if any
	if track.parent_track_id >= 0:
		var old_parent = get_track_by_id(track.parent_track_id)
		if old_parent:
			old_parent.child_track_ids.erase(track_id)

	# Add to new parent
	track.parent_track_id = group_id
	if not group.child_track_ids.has(track_id):
		group.child_track_ids.append(track_id)

	return true


# ============================================================================
# SERIALIZATION
# ============================================================================

# Serialize to JSON
func to_json() -> Dictionary:
	# Serialize clip pool
	var clips_array = []
	for clip_id in clips.keys():
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
