class_name Track extends RefCounted

enum TrackType { AUDIO, INSTRUMENT, FOLDER }

# ============================================================================
# SIGNALS
# ============================================================================

signal clip_instance_added(instance: ClipInstance)
signal clip_instance_removed(instance: ClipInstance)
signal name_changed(new_name: String)
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
var _name: String = "Track"

var name: String:
	get:
		return _name
	set(value):
		if _name != value:
			_name = value
			
			# If syncing to channel, update channel name too
			if name_by_channel and _linked_channel:
				_linked_channel.set_name(value)
			else:
				name_changed.emit(_name)

var type: TrackType = TrackType.INSTRUMENT
var _color: Color = Color.WHITE
var color_by_channel: bool = true  # If true, color syncs with default_channel_id's color
var name_by_channel: bool = true  # If true, name syncs with default_channel_id's name
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
			var old_channel_id = _default_channel_id
			var is_now_routed = value >= 0
			_default_channel_id = value
			default_channel_id_changed.emit(value)
			
			# Handle channel registration for bi-directional linking
			_update_channel_registration(old_channel_id, value)
			
			# Handle connection state changes
			if _is_connected:
				if is_now_routed:
					# Update routing to new channel
					AudioEngineOSC.send("/track/%d/route" % id, [value])
				else:
					# Routing removed, disconnect
					disconnect_from_engine()
			# Note: We don't auto-connect here if not connected
			# The Project will call connect_to_engine() when appropriate

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
var _height: int = 48  # Track height in pixels
var folded: bool = false  # Collapsed in UI
var muted: bool = false
var solo: bool = false
var armed: bool = false  # Record armed

# Connection state
var _is_connected: bool = false

# Channel linking (for bi-directional color/name sync)
var _linked_channel: Channel = null
var _project_ref: Project = null  # reference to project for channel lookup

# ============================================================================
# LIFECYCLE
# ============================================================================

func _init(track_id: int = -1):
	"""Initialize track with unique ID."""
	id = track_id
	_color = Color.from_hsv(randf(), randf_range(0.4, 0.8), randf_range(0.3, 0.6))


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
	if color_by_channel and _linked_channel:
		return _linked_channel.color
	return _color


func set_color(new_color: Color) -> void:
	"""Set track's color and emit signal."""
	_color = new_color
	
	# If syncing to channel, update channel color too
	if color_by_channel and _linked_channel:
		_linked_channel.set_color(new_color)
	else:
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


func set_mute(value: bool) -> void:
	"""Set mute state. If linked to a channel, delegates to channel's set_mute."""
	muted = value
	if _linked_channel:
		_linked_channel.set_mute(value)


func set_solo(value: bool) -> void:
	"""Set solo state. If linked to a channel, delegates to channel's set_solo."""
	solo = value
	if _linked_channel:
		_linked_channel.set_solo(value)


func set_armed(value: bool) -> void:
	"""Set record arm state. If linked to a channel, delegates to channel's set_record_armed."""
	armed = value
	if _linked_channel:
		_linked_channel.set_record_armed(value)


# ============================================================================
# CHANNEL LINKING
# ============================================================================

func set_project_ref(project: Project) -> void:
	"""Set project reference for channel lookup."""
	_project_ref = project
	# Update channel link immediately if we have a routing
	if _default_channel_id >= 0:
		_update_channel_link()


func _update_channel_registration(old_channel_id: int, new_channel_id: int) -> void:
	"""Update channel registration when routing changes."""
	if not _project_ref:
		return
	
	# Unregister from old channel
	if old_channel_id >= 0:
		var old_channel = _project_ref.get_channel_by_id(old_channel_id)
		if old_channel:
			old_channel.unregister_track(self)
	
	# Register with new channel
	if new_channel_id >= 0:
		var new_channel = _project_ref.get_channel_by_id(new_channel_id)
		if new_channel:
			new_channel.register_track(self)
			_linked_channel = new_channel
			
			# Sync color/name from channel if enabled
			if color_by_channel:
				_color = new_channel.color
				color_changed.emit(_color)
			if name_by_channel:
				_name = new_channel.name
				name_changed.emit(_name)
			
			# Sync mute/solo/armed state TO channel (track state is authoritative)
			new_channel.set_mute(muted)
			new_channel.set_solo(solo)
			new_channel.set_record_armed(armed)
		else:
			_linked_channel = null
	else:
		_linked_channel = null


func _update_channel_link() -> void:
	"""Update the linked channel reference."""
	if not _project_ref or _default_channel_id < 0:
		_linked_channel = null
		return
	
	_linked_channel = _project_ref.get_channel_by_id(_default_channel_id)


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
		
		print("[Track %d] Connected to audio engine (routed to channel %d)" % [id, default_channel_id])
	else:
		# Track not routed to a channel - don't connect yet
		print("[Track %d] Not connected (no routing)" % id)


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

	# Sync instance parameters (always sync clip_offset, even if 0, to initialize engine state)
	if instance.clip_offset != 0:
		AudioEngineOSC.send("/track/%d/instance/%s/set_position" % [id, instance.id], [
			instance.start_ticks,
			instance.duration_ticks,
			instance.clip_offset
		])
	
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


func _on_clip_note_added(_note: MidiNoteData, _instance: ClipInstance) -> void:
	"""Handle when a note is added to the source clip."""
	# Clip changes are handled by Project.gd which syncs the clip to engine
	# Engine automatically updates all instances during playback
	pass


func _on_clip_note_removed(_note: MidiNoteData, _instance: ClipInstance) -> void:
	"""Handle when a note is removed from the source clip."""
	# Clip changes are handled by Project.gd which syncs the clip to engine
	# Engine automatically updates all instances during playback
	pass


func _on_clip_note_changed(_note: MidiNoteData, _instance: ClipInstance) -> void:
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
		"name_by_channel": name_by_channel,
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
	track.name_by_channel = data.get("name_by_channel", true)
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
