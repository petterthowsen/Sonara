class_name Track extends RefCounted

enum TrackType { AUDIO, INSTRUMENT, FOLDER }

# ============================================================================
# SIGNALS
# ============================================================================

signal clip_instance_added(instance: ClipInstance)
signal clip_instance_removed(instance: ClipInstance)
signal color_changed(new_color: Color)
signal height_changed(new_height: int)
signal default_channel_id_changed(new_channel_id: int)
signal order_changed(new_order: int)
signal parent_changed(new_parent_id: int)

# ============================================================================
# PROPERTIES
# ============================================================================

# Unique ID (set in _init, immutable)
var id: int = -1

# Basic properties
var name: String = "Track"
var type: TrackType = TrackType.INSTRUMENT
var _color: Color = Color.WHITE
var color_by_channel: bool = true  # If true, color syncs with default_channel_id's color
var _order: int = 0  # Display order in arranger (lower = top, higher = bottom)

var order: int:
	get:
		return _order
	set(value):
		if _order != value:
			_order = value
			order_changed.emit(_order)

# Timeline data (PPQ-based positions)
var clip_instances: Array[ClipInstance] = []  # Array of ClipInstance objects
var automation_lanes: Array = []  # Array of AutomationLane objects

# Routing
var _default_channel_id: int = -1  # -1 = no routing, otherwise ID of Channel

var default_channel_id: int:
	get:
		return _default_channel_id
	set(value):
		if _default_channel_id != value:
			_default_channel_id = value
			default_channel_id_changed.emit(value)

# Grouping/hierarchy
var _parent_track_id: int = -1  # -1 = top level, otherwise ID of parent Track

var parent_track_id: int:
	get:
		return _parent_track_id
	set(value):
		if _parent_track_id != value:
			_parent_track_id = value
			parent_changed.emit(_parent_track_id)

var child_track_ids: Array[int] = []  # For FOLDER tracks, IDs of child tracks
var is_folder_expanded: bool = true  # UI state for folder tracks

# UI state
var _height: int = 38  # Track height in pixels
var folded: bool = false  # Collapsed in UI
var muted: bool = false
var solo: bool = false
var armed: bool = false  # Record armed

# Connection state
var _is_connected: bool = false

# ============================================================================
# LIFECYCLE
# ============================================================================

func _init(track_id: int = -1):
	"""Initialize track with unique ID."""
	id = track_id


# ============================================================================
# PROPERTIES
# ============================================================================

func get_nesting_level(project: Project = null) -> int:
	"""Calculate nesting level by traversing parent chain. Returns 0 for top-level tracks."""
	if _parent_track_id < 0:
		return 0
	
	if project == null:
		# Can't calculate without project reference
		return 0
	
	var level = 0
	var current_parent_id = _parent_track_id
	var visited_ids = []  # Prevent infinite loops
	
	while current_parent_id >= 0:
		# Guard against circular references
		if current_parent_id in visited_ids:
			push_error("[Track %d] Circular parent reference detected!" % id)
			break
		visited_ids.append(current_parent_id)
		
		level += 1
		var parent = project.get_track_by_id(current_parent_id)
		if parent == null:
			break
		current_parent_id = parent._parent_track_id
	
	return level


func get_color() -> Color:
	"""Get track color, either from channel or own color."""
	if color_by_channel and default_channel_id >= 0:
		# Try to get color from default channel
		# This requires access to project, which we don't have here
		# So we rely on the caller to sync this
		pass
	return _color


func set_color(new_color: Color) -> void:
	"""Set track's color and emit signal."""
	_color = new_color
	color_changed.emit(_color)


# Shorthand property for compatibility
var color: Color:
	get:
		return get_color()
	set(value):
		set_color(value)


# Color for the track in the tracklist
# It depends on user config and can be muted or saturated.
var track_color : Color:
	get:
		var c = color
		c.v = clamp(c.v, 0.3, 0.7)
		c.s = clamp(c.s, 0.1, 0.8)
		return c
	set(value):
		track_color = color


func set_height(new_height: int) -> void:
	"""Set track height and emit signal."""
	_height = new_height
	height_changed.emit(_height)


# Shorthand property for height
var height: int:
	get:
		return _height
	set(value):
		set_height(value)


# ============================================================================
# AUDIO ENGINE SYNC
# ============================================================================

func connect_to_engine() -> void:
	"""Connect to audio engine: sync initial state and all clip instances."""
	if _is_connected:
		return

	# Create track in audio engine if routed to a channel
	if default_channel_id >= 0:
		AudioEngineOSC.send("/track/%d/create" % id, [default_channel_id])

		# Mark as connected BEFORE syncing instances (so _sync_clip_instance_to_engine doesn't early-return)
		_is_connected = true

		# Sync all clip instances
		for instance in clip_instances:
			_sync_clip_instance_to_engine(instance)

			# Listen to source clip changes to re-sync
			if instance.clip:
				instance.clip.midi_note_added.connect(_on_clip_note_added.bind(instance))
				instance.clip.midi_note_removed.connect(_on_clip_note_removed.bind(instance))
				instance.clip.midi_note_changed.connect(_on_clip_note_changed.bind(instance))
	else:
		# Track not routed to a channel, but still mark as connected
		_is_connected = true

	print("[Track %d] Connected to audio engine" % id)


func disconnect_from_engine() -> void:
	"""Disconnect from audio engine."""
	if not _is_connected:
		return

	# Remove all clip instances from engine
	if default_channel_id >= 0:
		for instance in clip_instances:
			AudioEngineOSC.send("/track/%d/remove_instance" % id, [instance.id])

	_is_connected = false
	print("[Track %d] Disconnected from audio engine" % id)


func _sync_clip_instance_to_engine(instance: ClipInstance) -> void:
	"""Sync clip instance to the audio engine using new clip/instance API."""
	if not _is_connected:
		print("[Track %d] WARNING: _sync_clip_instance_to_engine called but not connected!" % id)
		return
	
	if not instance.clip:
		print("[Track %d] WARNING: instance %s has no clip reference!" % [id, instance.id])
		return

	# Send clip instance to engine
	# Engine will resolve notes from the clip pool during playback
	print("[Track %d] Syncing instance %s (clip: %s) to engine" % [id, instance.id, instance.clip_id])
	AudioEngineOSC.send("/track/%d/add_instance" % id, [
		instance.id,
		instance.clip_id,
		instance.start_ticks,
		instance.duration_ticks
	])

	# Sync instance parameters
	if instance.transpose != 0:
		AudioEngineOSC.send("/track/%d/instance/%s/set_transpose" % [id, instance.id], [instance.transpose])

	if instance.gain_offset != 0.0:
		AudioEngineOSC.send("/track/%d/instance/%s/set_gain" % [id, instance.id], [instance.gain_offset])

	if instance.muted:
		AudioEngineOSC.send("/track/%d/instance/%s/set_mute" % [id, instance.id], [1])

	if instance.loop_enabled:
		AudioEngineOSC.send("/track/%d/instance/%s/set_loop" % [id, instance.id], [
			1,
			instance.loop_start_ticks,
			instance.loop_length_ticks
		])


func _on_clip_note_added(note: MidiNoteData, instance: ClipInstance) -> void:
	"""Handle when a note is added to the source clip."""
	# Clip changes are handled by Project.gd which syncs the clip to engine
	# Engine automatically updates all instances during playback
	pass


func _on_clip_note_removed(note: MidiNoteData, instance: ClipInstance) -> void:
	"""Handle when a note is removed from the source clip."""
	# Clip changes are handled by Project.gd which syncs the clip to engine
	# Engine automatically updates all instances during playback
	pass


func _on_clip_note_changed(note: MidiNoteData, instance: ClipInstance) -> void:
	"""Handle when a note is changed in the source clip."""
	# Clip changes are handled by Project.gd which syncs the clip to engine
	# Engine automatically updates all instances during playback
	pass


func _clear_clip_instance_from_engine(instance: ClipInstance) -> void:
	"""Remove clip instance from the engine."""
	if not _is_connected:
		return

	AudioEngineOSC.send("/track/%d/remove_instance" % id, [instance.id])


# ============================================================================
# CLIP INSTANCE MANAGEMENT
# ============================================================================

func add_clip_instance(instance: ClipInstance) -> void:
	"""Add a clip instance to this track."""
	# Set the track reference on the instance (ClipInstances ALWAYS belong to a track)
	instance.track = self
	
	clip_instances.append(instance)

	# Sync to engine if connected
	if _is_connected:
		_sync_clip_instance_to_engine(instance)

		# Listen to source clip changes (but only if not already connected)
		if instance.clip:
			var callback_note_added = _on_clip_note_added.bind(instance)
			var callback_note_removed = _on_clip_note_removed.bind(instance)
			var callback_note_changed = _on_clip_note_changed.bind(instance)

			if not instance.clip.midi_note_added.is_connected(callback_note_added):
				instance.clip.midi_note_added.connect(callback_note_added)
			if not instance.clip.midi_note_removed.is_connected(callback_note_removed):
				instance.clip.midi_note_removed.connect(callback_note_removed)
			if not instance.clip.midi_note_changed.is_connected(callback_note_changed):
				instance.clip.midi_note_changed.connect(callback_note_changed)

	clip_instance_added.emit(instance)


func create_clip_instance(clip: Clip, start_ticks: int, duration_ticks: int = -1) -> ClipInstance:
	"""Create a new clip instance from a clip and add it to this track."""
	var instance = ClipInstance.new("", clip.id)
	instance.clip = clip
	instance.start_ticks = start_ticks

	# Use clip's content length if duration not specified
	if duration_ticks < 0:
		instance.duration_ticks = clip.get_content_length()
	else:
		instance.duration_ticks = duration_ticks

	# For audio clips, set loop_length to match clip content so looping works correctly
	if clip.type == Clip.ClipType.AUDIO:
		instance.loop_length_ticks = clip.content_length_ticks

	add_clip_instance(instance)
	return instance


func remove_clip_instance(instance: ClipInstance) -> void:
	"""Remove a clip instance from this track."""
	var idx = clip_instances.find(instance)
	if idx >= 0:
		clip_instances.remove_at(idx)

		# Remove MIDI notes from engine
		if _is_connected:
			_clear_clip_instance_from_engine(instance)

			# Disconnect from source clip signals (match the bind parameters)
			if instance.clip:
				var callback_note_added = _on_clip_note_added.bind(instance)
				var callback_note_removed = _on_clip_note_removed.bind(instance)
				var callback_note_changed = _on_clip_note_changed.bind(instance)

				if instance.clip.midi_note_added.is_connected(callback_note_added):
					instance.clip.midi_note_added.disconnect(callback_note_added)
				if instance.clip.midi_note_removed.is_connected(callback_note_removed):
					instance.clip.midi_note_removed.disconnect(callback_note_removed)
				if instance.clip.midi_note_changed.is_connected(callback_note_changed):
					instance.clip.midi_note_changed.disconnect(callback_note_changed)

		clip_instance_removed.emit(instance)


# ============================================================================
# SERIALIZATION
# ============================================================================

# Serialize to JSON
func to_json() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"type": TrackType.keys()[type],
		"color": _color.to_html(),
		"color_by_channel": color_by_channel,
		"order": _order,
		"clip_instances": clip_instances.map(func(i): return i.to_json()),
		"automation_lanes": automation_lanes.map(func(a): return a.to_json()) if not automation_lanes.is_empty() else [],
		"default_channel_id": default_channel_id,
		"parent_track_id": parent_track_id,
		"child_track_ids": child_track_ids,
		"is_folder_expanded": is_folder_expanded,
		"height": _height,
		"folded": folded,
		"muted": muted,
		"solo": solo,
		"armed": armed
	}


# Deserialize from JSON
static func from_json(data: Dictionary) -> Track:
	var track_id = data.get("id", -1)
	var track = Track.new(track_id)

	track.name = data.get("name", "Track")

	# Parse track type
	var type_str = data.get("type", "INSTRUMENT")
	track.type = TrackType.get(type_str) if TrackType.has(type_str) else TrackType.INSTRUMENT

	track._color = Color.from_string(data.get("color", "#FFFFFF"), Color.WHITE)
	track.color_by_channel = data.get("color_by_channel", true)
	track.order = data.get("order", 0)
	track.default_channel_id = data.get("default_channel_id", -1)
	track.parent_track_id = data.get("parent_track_id", -1)
	
	# Convert child_track_ids to typed array
	var child_ids = data.get("child_track_ids", [])
	track.child_track_ids.assign(child_ids)
	
	track.is_folder_expanded = data.get("is_folder_expanded", true)
	track.height = data.get("height", 38)
	track.folded = data.get("folded", false)
	track.muted = data.get("muted", false)
	track.solo = data.get("solo", false)
	track.armed = data.get("armed", false)

	# Load clip instances (clip references will be resolved by Project.from_json)
	for instance_data in data.get("clip_instances", []):
		if instance_data is Dictionary:
			var instance = ClipInstance.from_json(instance_data)
			# Set track reference immediately (before engine connection)
			instance.track = track
			track.clip_instances.append(instance)

	# TODO: Load automation when AutomationLane exists

	return track
