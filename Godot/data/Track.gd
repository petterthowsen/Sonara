class_name Track extends RefCounted

static var logger := Log.make("Track")

enum TrackType { AUDIO, INSTRUMENT, FOLDER, GROUP }

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
signal automation_lane_added(lane: AutomationLane)
signal automation_lane_removed(lane: AutomationLane)
signal automation_expanded_changed(expanded: bool)

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
		# Unique across the project's tracks and channels (a no-op until attached, e.g. from_json).
		var final_name := unique_name_for(value)
		if _name != final_name:
			var ch := get_linked_channel()
			_name = final_name
			if name_by_channel and ch and not ch.is_master:
				ch.set_name(final_name)
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
var automation_lanes: Array[AutomationLane] = []

# Routing
var _default_channel_id: int = -1  # -1 = no routing, otherwise ID of Channel

var default_channel_id: int:
	get:
		return _default_channel_id
	set(value):
		if _default_channel_id != value:
			var old_channel_id = _default_channel_id
			var is_now_routed = value >= 0

			# Routing removed: disconnect while default_channel_id still
			# reflects the old (>= 0) routing, since disconnect_from_engine()
			# checks default_channel_id to decide whether to remove clip
			# instances from the engine.
			if _is_connected and not is_now_routed:
				disconnect_from_engine()

			_default_channel_id = value
			default_channel_id_changed.emit(value)

			# Handle channel registration for bi-directional linking
			_update_channel_registration(old_channel_id, value)

			# The linked channel changed: every lane's target must be re-evaluated (REQ-024).
			refresh_automation_resolution()

			# Handle connection state changes
			if _is_connected and is_now_routed:
				# Update routing to new channel
				AudioEngineOSC.send("/track/%d/route" % id, [value])
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

var child_track_ids: Array[int] = []  # Child tracks of a folder or group
var is_folder_expanded: bool = true  # UI state for folder/group tracks

var _automation_expanded: bool = false

## The channel whose structure signals currently drive `refresh_automation_resolution`, so
## re-linking doesn't stack duplicate connections (REQ-024).
var _automation_watch_channel: Channel = null

## Whether this track's automation lane rows are disclosed in the arranger (REQ-014). Both
## arranger columns read it through AutomationRowOrder, so it lives on the model rather than on
## either TrackItem or the timeline row.
var automation_expanded: bool:
	get:
		return _automation_expanded
	set(value):
		if _automation_expanded != value:
			_automation_expanded = value
			automation_expanded_changed.emit(_automation_expanded)

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
var _project_ref: WeakRef = null  # weak reference to project for channel lookup, to avoid a Track<->Project cycle

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
	"""Get track color, either from the paired mixer channel or this track's own color."""
	if color_by_channel:
		var ch := get_linked_channel()
		if ch:
			return ch.color
	return _color


func set_color(new_color: Color) -> void:
	"""Set track color; push to the paired mixer channel when one exists."""
	_color = new_color
	var ch := get_linked_channel()
	if ch:
		logger.debug("[Track %d] set_color → channel %d (%s) type=%s" % [
			id, ch.id, ch.name, TrackType.keys()[type]
		])
		ch.set_color(new_color)
	color_changed.emit(_color)


# Shorthand property for compatibility
var color: Color:
	get:
		return get_color()
	set(value):
		set_color(value)


func set_height(new_height: int) -> void:
	"""Set track height and emit signal."""
	if _height == new_height:
		return
	_height = new_height
	height_changed.emit(_height)


# Shorthand property for height
var height: int:
	get:
		return _height
	set(value):
		set_height(value)


## Set display name (used by undoable property commands).
func set_name(new_name: String) -> void:
	name = new_name


## The name `set_name(desired)` would apply: suffixed if another track/channel uses it or it is reserved.
## Record this (not `desired`) in undo commands so redo reproduces the same name.
func unique_name_for(desired: String) -> String:
	var project := get_project_ref()
	if project == null:
		return desired
	return project.unique_name(desired, self)


## Take a color pushed from the paired channel without writing it back.
func apply_channel_color(new_color: Color) -> void:
	_color = new_color
	color_changed.emit(new_color)


## Take a name pushed from the paired channel without writing it back.
func apply_channel_name(new_name: String) -> void:
	_name = new_name
	name_changed.emit(new_name)


## True while this track is connected to the audio engine.
func is_engine_connected() -> bool:
	return _is_connected


func set_mute(value: bool) -> void:
	"""Set mute state. If linked to a channel, delegates to channel's set_mute."""
	muted = value
	var ch := get_linked_channel()
	if ch:
		ch.set_mute(value)


func set_solo(value: bool) -> void:
	"""Set solo state. If linked to a channel, delegates to channel's set_solo."""
	solo = value
	var ch := get_linked_channel()
	if ch:
		ch.set_solo(value)


func set_armed(value: bool) -> void:
	"""Set record arm state. If linked to a channel, delegates to channel's set_record_armed."""
	armed = value
	var ch := get_linked_channel()
	if ch:
		ch.set_record_armed(value)


# ============================================================================
# CHANNEL LINKING
# ============================================================================

func set_project_ref(project: Project) -> void:
	"""Set project reference (weak, to avoid a Track<->Project cycle) for channel lookup."""
	if project:
		_project_ref = weakref(project)
	get_linked_channel()


## Resolve the weakly-held project reference, if it's still alive.
func get_project_ref() -> Project:
	if _project_ref == null:
		return null
	return _project_ref.get_ref() as Project


func _update_channel_registration(old_channel_id: int, new_channel_id: int) -> void:
	"""Update channel registration when routing changes."""
	var project := get_project_ref()
	if not project:
		return

	# Unregister from old channel
	if old_channel_id >= 0:
		var old_channel = project.get_channel_by_id(old_channel_id)
		if old_channel:
			old_channel.unregister_track(self)

	# Register with new channel
	if new_channel_id >= 0:
		var new_channel = project.get_channel_by_id(new_channel_id)
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
			push_warning("[Track %d] _update_channel_registration: channel %d not in project.channels" % [
				id, new_channel_id
			])
	else:
		_linked_channel = null


## True when this folder is paired with a mixer bus (Folder Bus).
func is_folder_bus() -> bool:
	return type == TrackType.FOLDER and _default_channel_id >= 0


## True when this is a Group track (nested mix parent on the timeline).
func is_group() -> bool:
	return type == TrackType.GROUP


## True when this track can own child tracks (folder, group, or a channel that already has children).
func can_contain_tracks() -> bool:
	if type == TrackType.FOLDER or type == TrackType.GROUP:
		return true
	var ch := get_linked_channel()
	return ch != null and not ch.child_channel_ids.is_empty()


## True when this track can hold clips (not a folder or group header).
func has_clips() -> bool:
	return type != TrackType.FOLDER and type != TrackType.GROUP


## Pair this track with a mixer strip (instrument, group, or folder bus).
func pair_mixer_channel(ch: Channel) -> void:
	if ch == null:
		return
	if get_project_ref() == null:
		logger.error("[%d] pair_mixer_channel(%d) before set_project_ref" % [id, ch.id])
	color_by_channel = true
	name_by_channel = true
	if _default_channel_id == ch.id:
		_linked_channel = ch
		ch.register_track(self)
		return
	default_channel_id = ch.id
	logger.debug("[%d] pair_mixer_channel: channel %d (%s)" % [id, ch.id, ch.name])


## Mixer channel paired for color/name/mute: routed strip, group, or folder bus.
func get_linked_channel() -> Channel:
	return _ensure_linked_channel()


## Resolve the mixer channel from default_channel_id only (folders have no implicit bus).
func _ensure_linked_channel() -> Channel:
	if _default_channel_id < 0:
		_linked_channel = null
		return null

	if _linked_channel and _linked_channel.id == _default_channel_id:
		_linked_channel.register_track(self)
		return _linked_channel

	var project := get_project_ref()
	if project == null:
		# Not attached yet (during from_json) or the project was freed.
		return null

	var ch := project.get_channel_by_id(_default_channel_id)
	if ch == null:
		logger.error("[%d] '%s': default_channel_id %d is not in project.channels" % [
			id, _name, _default_channel_id
		])
		return null

	_linked_channel = ch
	ch.register_track(self)
	return ch


# ============================================================================
# AUDIO ENGINE SYNC
# ============================================================================

func connect_to_engine() -> void:
	"""Connect to audio engine: sync initial state and all clip instances."""
	if _is_connected:
		return

	# Folder and group tracks have no engine timeline (mixer pairing only).
	if type == TrackType.FOLDER or type == TrackType.GROUP:
		logger.info("[Track %d] %s not connected to engine (mixer pairing only)" % [
			id, "Group" if type == TrackType.GROUP else "Folder"
		])
		return

	# Create track in audio engine if routed to a channel
	if default_channel_id >= 0:
		AudioEngineOSC.send("/track/%d/create" % id, [default_channel_id])

		# Mark as connected BEFORE syncing instances (so _sync_clip_instance_to_engine doesn't early-return)
		_is_connected = true

		# Sync all clip instances
		for instance in clip_instances:
			_sync_clip_instance_to_engine(instance)

		# Sync all automation lanes (REQ-012)
		for lane in automation_lanes:
			lane.sync_to_engine()

		logger.info("[Track %d] Connected to audio engine (routed to channel %d)" % [id, default_channel_id])
	else:
		# Track not routed to a channel - don't connect yet
		logger.info("[Track %d] Not connected (no routing)" % id)


func disconnect_from_engine() -> void:
	"""Disconnect from audio engine."""
	if not _is_connected:
		return

	# Remove all clip instances from engine
	if default_channel_id >= 0:
		for instance in clip_instances:
			AudioEngineOSC.send("/track/%d/remove_instance" % id, [instance.id])

	# Automation lanes live on the engine's track record, so they go away with it; clearing the
	# connected flag makes a later connect_to_engine() resync them from scratch (REQ-012).
	_is_connected = false
	logger.info("[Track %d] Disconnected from audio engine" % id)


func _sync_clip_instance_to_engine(instance: ClipInstance) -> void:
	"""Sync clip instance to the audio engine using new clip/instance API."""
	if not _is_connected:
		logger.warn("[Track %d] WARNING: _sync_clip_instance_to_engine called but not connected!" % id)
		return

	if not instance.clip:
		logger.warn("[Track %d] WARNING: instance %s has no clip reference!" % [id, instance.id])
		return

	# Send clip instance to engine
	# Engine will resolve notes from the clip pool during playback
	logger.info("[Track %d] Syncing instance %s (clip: %s) to engine" % [id, instance.id, instance.clip_id])
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


## True when `[start_ticks, start_ticks + duration_ticks)` overlaps any instance on this track.
func has_clip_overlap(start_ticks: int, duration_ticks: int, exclude: Array[ClipInstance] = []) -> bool:
	var end_ticks := start_ticks + duration_ticks
	for other in clip_instances:
		if other == null or exclude.has(other):
			continue
		if start_ticks < other.start_ticks + other.duration_ticks and other.start_ticks < end_ticks:
			return true
	return false


func remove_clip_instance(instance: ClipInstance) -> void:
	"""Remove a clip instance from this track."""
	var idx = clip_instances.find(instance)
	if idx >= 0:
		clip_instances.remove_at(idx)

		# Remove MIDI notes from engine
		if _is_connected:
			_clear_clip_instance_from_engine(instance)

		clip_instance_removed.emit(instance)


# ============================================================================
# AUTOMATION LANE MANAGEMENT
# ============================================================================

## Add a lane, syncing it to the engine when this track is connected (REQ-001, REQ-012).
func add_automation_lane(lane: AutomationLane) -> void:
	lane.track = self
	automation_lanes.append(lane)
	# Evaluate the new lane's target against the linked channel before syncing (REQ-024).
	refresh_automation_resolution()
	if _is_connected:
		lane.sync_to_engine()
	automation_lane_added.emit(lane)


## Remove a lane, deleting it from the engine when connected.
func remove_automation_lane(lane: AutomationLane) -> void:
	var idx := automation_lanes.find(lane)
	if idx < 0:
		return
	automation_lanes.remove_at(idx)
	if _is_connected:
		AudioEngineOSC.send("/track/%d/automation/%s/delete" % [id, lane.id])
	lane.track = null
	automation_lane_removed.emit(lane)


## The lane driving `target` on this track, or null when none exists (REQ-015: used to skip
## parameters that already have a lane).
func get_automation_lane_for(target: AutomationTarget) -> AutomationLane:
	if target == null:
		return null
	var target_str := str(target)
	for lane in automation_lanes:
		if lane.target != null and str(lane.target) == target_str:
			return lane
	return null


# ============================================================================
# LANE RESOLUTION (REQ-024)
# ============================================================================

## Re-evaluate every lane's `resolved` flag against the linked channel. A lane whose target
## stopped resolving keeps its points, stops syncing to the engine, and logs exactly one
## warning; one that re-resolves (e.g. the device came back) is resynced so it drives again.
func refresh_automation_resolution() -> void:
	var ch := _ensure_linked_channel()
	_watch_automation_channel(ch)
	if automation_lanes.is_empty():
		return
	for lane in automation_lanes:
		var ok := lane.target != null and lane.target.is_resolvable(ch)
		if ok == lane.resolved:
			continue
		if ok:
			lane.set_resolved(true)
			if _is_connected:
				lane.sync_to_engine()
			logger.info("[Track %d] automation lane '%s' target resolves again" % [id, lane.id])
		else:
			lane.set_resolved(false)
			logger.warn("[Track %d] automation lane '%s' no longer resolves against channel %s; points kept, engine sync paused" % [
				id, lane.id, str(ch.id if ch else -1)])


## Subscribe to the linked channel's structure signals, any of which can change whether a lane
## target resolves (device added/removed/moved, plugin parameters loaded, sends changed).
## Idempotent, and disconnects from the previous channel on re-link.
func _watch_automation_channel(ch: Channel) -> void:
	if ch == _automation_watch_channel:
		return
	if _automation_watch_channel != null:
		for sig_name in _automation_channel_signals():
			var old_sig: Signal = _automation_watch_channel.get(sig_name)
			if old_sig.is_connected(_on_automation_channel_structure_changed):
				old_sig.disconnect(_on_automation_channel_structure_changed)
	_automation_watch_channel = ch
	if ch != null:
		for sig_name in _automation_channel_signals():
			var sig: Signal = ch.get(sig_name)
			if not sig.is_connected(_on_automation_channel_structure_changed):
				sig.connect(_on_automation_channel_structure_changed)


static func _automation_channel_signals() -> Array[String]:
	return [
		"device_added",
		"device_removed",
		"device_moved",
		"device_parameters_updated",
		"send_added",
		"send_removed",
	]


func _on_automation_channel_structure_changed(_a = null, _b = null) -> void:
	refresh_automation_resolution()


# ============================================================================
# SERIALIZATION
# ============================================================================

# Serialize to JSON
func to_json() -> Dictionary:
	var data := JsonFields.write(self, JSON_FIELDS)
	data.merge({
		"id": id,
		"type": TrackType.keys()[type],
		"color": Utils.color_to_json(_color),
		"clip_instances": clip_instances.map(func(i): return i.to_json()),
		"automation_lanes": automation_lanes.map(func(a): return a.to_json()),
		"child_track_ids": child_track_ids.duplicate(),
	})
	return data


## Plain fields copied by JsonFields (through their setters); defaults come from the initializers.
const JSON_FIELDS: Array[String] = [
	"name", "color_by_channel", "name_by_channel", "order", "default_channel_id",
	"parent_track_id", "is_folder_expanded", "height", "folded", "muted", "solo", "armed",
	"automation_expanded",
]


# Deserialize from JSON
static func from_json(data: Dictionary) -> Track:
	var track_id = data.get("id", -1)
	var track = Track.new(track_id)

	track.type = TrackType.get(str(data.get("type", "")), track.type)
	track._color = Utils.color_from_json(data.get("color"), track._color)
	JsonFields.read(track, data, JSON_FIELDS)
	track.child_track_ids.assign(data.get("child_track_ids", []))

	# Load clip instances (clip references will be resolved by Project.from_json)
	for instance_data in data.get("clip_instances", []):
		if instance_data is Dictionary:
			var instance = ClipInstance.from_json(instance_data)
			# Set track reference immediately (before engine connection)
			instance.track = track
			track.clip_instances.append(instance)

	# Load automation lanes. A missing key loads as zero lanes; a lane/point without an id gets
	# one assigned by index; retired curve names load as LINEAR (REQ-023).
	var lane_index := 0
	for lane_data in data.get("automation_lanes", []):
		if lane_data is Dictionary:
			var lane := AutomationLane.from_json(lane_data, "lane%d" % lane_index)
			lane.track = track
			track.automation_lanes.append(lane)
			lane_index += 1

	return track
