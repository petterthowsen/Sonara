class_name Channel extends RefCounted

static var logger := Log.make("Channel")

# Channel types
enum ChannelType {
	INSTRUMENT,  # MIDI instrument track
	AUDIO,       # Audio track
	BUS,         # Bus channel (right pane, send/route target)
	GROUP        # Group mix parent (left pane, nested children)
}

# Where a channel's note map comes from (REQ-001)
enum NoteMapMode {
	NONE,   # No labels or colours
	AUTO,   # Derived live from the channel's instrument (a Drum Machine today)
	NAMED,  # A user map, embedded in the project as `note_map`
}

# Pan modes (Cubase-style)
enum PanMode {
	STEREO_COMBINED,  # Single pan knob controls stereo balance (Cubase default)
	STEREO_DUAL,      # Separate L/R pan controls
	STEREO_BALANCE,   # Balance between L and R channels
	MONO              # Mono panner (single channel)
}

# ============================================================================
# SIGNALS
# ============================================================================

signal name_changed(name : String)
signal color_changed(color : Color)
signal volume_changed(value: float)
signal pan_changed(pan_left: float, pan_right: float)
signal pan_mode_changed(pan_mode: PanMode)
signal mute_changed(value: bool)
signal solo_changed(value: bool)
signal peak_updated(left: float, right: float, rms_left: float, rms_right: float)
signal route_changed(output_id: int)
signal hierarchy_changed

## Assignment, embedded map or Drum View preference changed. Purely a UI concern:
## note maps are labels and are never sent to the engine.
signal note_map_changed

# MIDI signals
signal midi_input_device_changed(device_id: int)
signal record_armed_changed(armed: bool)

# Send signals
signal send_added(target_channel_id: int, send_config: SendConfig)
signal send_removed(target_channel_id: int)
signal send_changed(target_channel_id: int, send_config: SendConfig)

# Device chain signals
signal device_added(device_instance: DeviceInstance, position: int)
signal device_removed(position: int, device_id: String)
signal device_moved(from_position: int, to_position: int)
signal device_parameter_changed(device_instance: DeviceInstance, param_id: int, value: float)
signal device_parameters_updated(device_instance: DeviceInstance)  # Emitted when plugin parameters are loaded

# ============================================================================
# PROPERTIES
# ============================================================================

# Unique ID (set in _init, immutable)
var id: int = -1

# Basic properties
var name: String = "Channel"
var color: Color = Color.WHITE
var order: int = 0  # Display order in mixer (lower = left, higher = right)

# Audio properties
var volume: float = 0.0  # dB (-60 to +12), initialized in _init() based on channel ID
var pan: float = 0.0     # -1.0 (L) to +1.0 (R) for STEREO_COMBINED/MONO
var pan_left: float = 0.0   # For STEREO_DUAL mode
var pan_right: float = 0.0  # For STEREO_DUAL mode
var pan_mode: PanMode = PanMode.STEREO_COMBINED

var mute: bool = false
var solo: bool = false
var phase_invert: bool = false

# Channel type and properties
var channel_type: ChannelType = ChannelType.INSTRUMENT
var device_output_id: int = 1000  # Hardware output device (1000+ reserved)

# Routing
var output_channel_id: int = 1  # Channel to route to (1 = master by default)
var send_channels: Array = []  # Array of SendConfig objects

# Mixer nesting (independent of output_channel_id; Folder Bus routing does not nest)
var parent_channel_id: int = -1
var child_channel_ids: Array[int] = []
var is_children_expanded: bool = true
## Extra device bus this nested strip receives (-1 = not an aux return, or an empty drum pad).
var aux_bus_index: int = -1
## Drum Machine pad note this strip is the return of (-1 = not a pad return). Stays set while
## the pad is empty, so a device added on that note adopts this return (see AuxReturnSync).
var aux_pad_note: int = -1
## Number of aux-out bus slots last sent to the engine, so stale slots can be cleared. Not persisted.
var aux_out_sent_count: int = 0

# Note map (labels and colours for MIDI pitches; never sent to the engine)
var note_map_mode: NoteMapMode = NoteMapMode.AUTO
## The embedded copy of a named map. Null unless note_map_mode is NAMED. Kept in
## the project so it survives a machine whose library lacks the map (REQ-011).
var note_map: NoteMap = null
## Whether this channel's clips open in Drum View: -1 unset, 0 piano roll, 1 Drum
## View. Unset resolves per effective map at open time (REQ-028).
var drum_view: int = -1

# MIDI input configuration
var midi_input_device: int = -2  # -3=none, -2=all, -1=virtual keyboard, 0+=physical device
var record_armed: bool = false

# Device chain
var devices: Array[DeviceInstance] = []  # Ordered list of devices on this channel

# Metering (runtime state, not serialized)
var peak_left: float = 0.0   # Current peak level (linear 0.0-1.0+)
var peak_right: float = 0.0
var rms_left: float = 0.0    # RMS level
var rms_right: float = 0.0

# Connection state
var _is_connected: bool = false

## Owning project (weak, to avoid a Channel<->Project cycle). Set by Project.
var _project_ref: WeakRef = null

# Track routing (tracks that route to this channel)
var routed_tracks: Array[Track] = []

# Helper properties
var is_bus : bool:
	get:
		return channel_type == ChannelType.BUS

var is_master : bool:
	get:
		return id == 1

var is_group_channel : bool:
	get:
		return channel_type == ChannelType.GROUP


## True while this channel is connected to the audio engine.
func is_engine_connected() -> bool:
	return _is_connected


## Record the owning project; null detaches the channel (on removal).
func set_project(project: Project) -> void:
	_project_ref = weakref(project) if project else null


## Owning project, or null if detached or the project has been freed.
func get_project() -> Project:
	if _project_ref == null:
		return null
	return _project_ref.get_ref() as Project


## True when output is forced to the mixer parent (group children).
func route_locked() -> bool:
	return parent_channel_id >= 0


## True when this strip is a drum-pad or plugin extra-out return.
func is_aux_return() -> bool:
	return aux_bus_index >= 0 or aux_pad_note >= 0


## True when this strip is a Drum Machine pad's return (the pad may be empty).
func is_pad_return() -> bool:
	return aux_pad_note >= 0


## True when this strip is an extra-out return of a non-drum device (can't be deleted on its own).
func is_plugin_return() -> bool:
	return aux_bus_index >= 0 and aux_pad_note < 0


## Notify UI that parent/children membership changed.
func notify_hierarchy_changed() -> void:
	hierarchy_changed.emit()


# ============================================================================
# LIFECYCLE
# ============================================================================

func _init(channel_id: int = -1):
	"""Initialize channel with unique ID."""
	id = channel_id
	# Master channel (ID 1) defaults to 0 dB, others default to -6 dB for headroom
	if id == 1:
		volume = 0.0
	else:
		volume = -6.0


# ============================================================================
# AUDIO ENGINE SYNC
# ============================================================================

func connect_to_engine() -> void:
	"""Connect to audio engine: setup listeners and sync initial state."""
	if _is_connected:
		return

	# Listen for incoming peak meter updates
	AudioEngineOSC.listen("/channel/%d/peak" % id, _on_peak_received)

	# Sync current state to engine
	sync_to_engine()
	
	# Connect all device instances to engine
	for device_inst in devices:
		device_inst.connect_to_engine()

	_is_connected = true
	# Drum pad / plugin extra-out maps require _is_connected (see AuxReturnSync).
	AuxReturnSync.sync_aux_map_to_engine(self)
	logger.info("[%d] Connected to audio engine" % id)


func disconnect_from_engine() -> void:
	"""Disconnect from audio engine."""
	if not _is_connected:
		return

	# Unlisten from OSC messages
	AudioEngineOSC.unlisten("/channel/%d/peak" % id, _on_peak_received)
	
	# Disconnect all device instances from engine
	for device_inst in devices:
		device_inst.disconnect_from_engine()
	
	# DeviceInstances handle their own parameter listeners now

	# Drop back-references to tracks so this channel can be freed even if
	# a Track elsewhere still holds a weak project ref pointing at us.
	routed_tracks.clear()

	_is_connected = false
	logger.info("[%d] Disconnected from audio engine" % id)


func sync_to_engine() -> void:
	"""Sync current channel state to audio engine."""
	AudioEngineOSC.send("/channel/%d/create" % id, [name])
	AudioEngineOSC.send("/channel/%d/volume" % id, [volume])
	AudioEngineOSC.send("/channel/%d/pan_mode" % id, [pan_mode])
	if pan_mode == PanMode.STEREO_DUAL:
		AudioEngineOSC.send("/channel/%d/pan" % id, [pan_left, pan_right])
	else:
		AudioEngineOSC.send("/channel/%d/pan" % id, [pan])
	AudioEngineOSC.send("/channel/%d/mute" % id, [1 if mute else 0])
	AudioEngineOSC.send("/channel/%d/solo" % id, [1 if solo else 0])

	# Sync MIDI routing config
	AudioEngineOSC.send("/channel/%d/midi_input_device" % id, [midi_input_device])
	AudioEngineOSC.send("/channel/%d/record_armed" % id, [1 if record_armed else 0])

	# Master channel: routes to device output
	if is_master:
		AudioEngineOSC.send("/channel/%d/route" % id, [device_output_id])
	else:
		# Regular channels: route to output channel
		AudioEngineOSC.send("/channel/%d/route" % id, [output_channel_id])
	
	# Sync all sends to engine
	for send in send_channels:
		AudioEngineOSC.send("/channel/%d/send/%d/add" % [id, send.target_channel_id], [send.amount, 1 if send.pre_fader else 0])
		if send.muted:
			AudioEngineOSC.send("/channel/%d/send/%d/mute" % [id, send.target_channel_id], [1])
	
	# Sync all devices to engine (for project loading)
	for device_inst in devices:
		_send_add_device_osc(device_inst, null)
		_sync_device_tree_to_engine(device_inst)


# ============================================================================
# PROPERTY SETTERS (with audio engine sync where appropriate)
# ============================================================================
## Rename; suffixed (`Drums 2`) when another track/channel uses the name or it is reserved.
func set_name(new_name : String):
	name = unique_name_for(new_name)
	name_changed.emit(name)
	
	# Update all routed tracks that sync name from channel
	for track in routed_tracks:
		if track.name_by_channel:
			track.apply_channel_name(name)


## The name `set_name(desired)` would apply. Paired tracks don't count as a collision.
func unique_name_for(desired: String) -> String:
	var project := get_project()
	if project == null:
		return desired
	return project.unique_name(desired, null, self, "Channel")


## Switch between None, Auto and a named map. Assigning NAMED without a map
## leaves the channel showing nothing until set_note_map() supplies one.
func set_note_map_mode(mode: NoteMapMode) -> void:
	if note_map_mode == mode:
		return
	note_map_mode = mode
	note_map_changed.emit()


## Assign (a copy of) a named map, or null to clear it. Passing a map switches the
## channel to NAMED; the copy is what keeps library and project independent
## (REQ-010, REQ-026).
func set_note_map(map: NoteMap) -> void:
	if map == null:
		if note_map == null:
			return
		note_map = null
		if note_map_mode == NoteMapMode.NAMED:
			note_map_mode = NoteMapMode.AUTO
		note_map_changed.emit()
		return
	note_map = map.duplicate_map()
	note_map_mode = NoteMapMode.NAMED
	note_map_changed.emit()


## -1 unset, 0 piano roll, 1 Drum View (REQ-028).
func set_drum_view(value: int) -> void:
	var clamped := clampi(value, -1, 1)
	if drum_view == clamped:
		return
	drum_view = clamped
	note_map_changed.emit()


func set_color(new_color : Color):
	"""Store the color as-is and push it to paired tracks (routed strips, folder buses, and groups)."""
	if color == new_color:
		return
	color = new_color
	logger.debug("[%d] set_color %s routed_tracks=%d" % [id, color, routed_tracks.size()])
	color_changed.emit(color)
	_sync_color_to_paired_tracks(new_color)


func set_volume(value: float) -> void:
	"""Set volume and sync to audio engine."""
	volume = clamp(value, -60.0, 12.0)
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/volume" % id, [volume])
	volume_changed.emit(volume)


func set_pan_mode(mode : PanMode) -> void:
	pan_mode = mode

	# When switching to STEREO_DUAL mode, initialize pan_left and pan_right to default values
	if mode == PanMode.STEREO_DUAL:
		pan_left = -1.0
		pan_right = 1.0

	if _is_connected:
		AudioEngineOSC.send("/channel/%d/pan_mode" % id, [pan_mode])
		# Also sync pan values when switching modes
		if mode == PanMode.STEREO_DUAL:
			AudioEngineOSC.send("/channel/%d/pan" % id, [pan_left, pan_right])
		else:
			AudioEngineOSC.send("/channel/%d/pan" % id, [pan])

	pan_mode_changed.emit(pan_mode)
	# Emit pan_changed to update UI with the new pan values
	pan_changed.emit(pan_left, pan_right)


func set_pan(pan_l: float, pan_r : float = 0.0) -> void:
	"""Set pan and sync to audio engine."""
	if pan_mode == PanMode.STEREO_COMBINED:
		pan = clamp(pan_l, -1.0, 1.0)
		pan_left = pan
		if _is_connected:
			logger.debug("[%d] sending channel pan to " % id, pan)
			AudioEngineOSC.send("/channel/%d/pan" % id, [pan])
	elif pan_mode == PanMode.STEREO_DUAL:
		pan_left = clamp(pan_l, -1.0, 1.0)
		pan_right = clamp(pan_r, -1.0, 1.0)
		if _is_connected:
			AudioEngineOSC.send("/channel/%d/pan" % id, [pan_left, pan_right])
	
	pan_changed.emit(pan_left, pan_right)


func set_mute(value: bool) -> void:
	"""Set mute and sync to audio engine."""
	mute = value
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/mute" % id, [1 if mute else 0])
	mute_changed.emit(mute)


func set_solo(value: bool) -> void:
	"""Set solo and sync to audio engine."""
	solo = value
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/solo" % id, [1 if solo else 0])
	solo_changed.emit(solo)


func set_route(output_id: int) -> void:
	"""Set output routing and sync to audio engine.

	Routing rules:
	- INSTRUMENT/AUDIO channels: route to Master (ID 1) or BUS channels
	- BUS channels: route to Master (ID 1) or other BUS channels

	This prevents invalid hierarchies like INSTRUMENT -> INSTRUMENT.
	The UI filters available options; this is a safety check for edge cases.
	"""
	# Validate routing: reject self-routing to prevent feedback loops
	if output_id == id:
		logger.warn("[%d] Cannot route to self, ignoring route to %d" % [id, output_id])
		return

	output_channel_id = output_id
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/route" % id, [output_channel_id])
	route_changed.emit(output_channel_id)


func set_midi_input_device(device_id: int):
	## Assign MIDI input device to this channel.
	## -3 = no MIDI, -2 = all devices, -1 = virtual keyboard, 0+ = specific device ID.
	if midi_input_device != device_id:
		midi_input_device = device_id
		if _is_connected:
			AudioEngineOSC.send("/channel/%d/midi_input_device" % id, [midi_input_device])
		midi_input_device_changed.emit(device_id)
		logger.info("[%d] MIDI input device set to %d" % [id, device_id])


func set_record_armed(armed: bool):
	## Arm/disarm channel for MIDI recording.
	if record_armed != armed:
		record_armed = armed
		if _is_connected:
			AudioEngineOSC.send("/channel/%d/record_armed" % id, [1 if armed else 0])
		record_armed_changed.emit(armed)
		logger.info("[%d] Record armed: %s" % [id, armed])


# ============================================================================
# SEND MANAGEMENT
# ============================================================================

func add_send(target_channel_id: int, amount_db: float = -12.0, pre_fader: bool = false) -> void:
	"""Add a send to a BUS channel and sync to audio engine."""
	# Check if send already exists
	for send in send_channels:
		if send.target_channel_id == target_channel_id:
			logger.warn("[%d] Send to channel %d already exists" % [id, target_channel_id])
			return
	
	# Validate target is not self
	if target_channel_id == id:
		logger.warn("[%d] Cannot send to self" % id)
		return
	
	# Create send config
	var send_config = SendConfig.new()
	send_config.target_channel_id = target_channel_id
	send_config.amount = amount_db
	send_config.pre_fader = pre_fader
	send_config.muted = false
	
	# Add to local array
	send_channels.append(send_config)
	
	# Sync to engine
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/send/%d/add" % [id, target_channel_id], [amount_db, 1 if pre_fader else 0])
	
	send_added.emit(target_channel_id, send_config)
	logger.info("[%d] Send added to channel %d (%.1f dB, %s)" % [id, target_channel_id, amount_db, "pre-fader" if pre_fader else "post-fader"])


func remove_send(target_channel_id: int) -> void:
	"""Remove a send and sync to audio engine."""
	var found = false
	for i in range(send_channels.size()):
		if send_channels[i].target_channel_id == target_channel_id:
			send_channels.remove_at(i)
			found = true
			break
	
	if not found:
		logger.warn("[%d] Send to channel %d not found" % [id, target_channel_id])
		return
	
	# Sync to engine
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/send/%d/remove" % [id, target_channel_id])
	
	send_removed.emit(target_channel_id)
	logger.info("[%d] Send removed to channel %d" % [id, target_channel_id])


func set_send_amount(target_channel_id: int, amount_db: float) -> void:
	"""Set send level and sync to audio engine."""
	var send_config = get_send(target_channel_id)
	if not send_config:
		logger.warn("[%d] Send to channel %d not found" % [id, target_channel_id])
		return
	
	send_config.amount = clamp(amount_db, -60.0, 12.0)
	
	# Sync to engine
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/send/%d/amount" % [id, target_channel_id], [send_config.amount])
	
	send_changed.emit(target_channel_id, send_config)


func set_send_pre_fader(target_channel_id: int, pre_fader: bool) -> void:
	"""Set send pre/post fader and sync to audio engine."""
	var send_config = get_send(target_channel_id)
	if not send_config:
		logger.warn("[%d] Send to channel %d not found" % [id, target_channel_id])
		return
	
	send_config.pre_fader = pre_fader
	
	# Sync to engine
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/send/%d/pre_fader" % [id, target_channel_id], [1 if pre_fader else 0])
	
	send_changed.emit(target_channel_id, send_config)
	logger.info("[%d] Send to channel %d set to %s" % [id, target_channel_id, "pre-fader" if pre_fader else "post-fader"])


func set_send_mute(target_channel_id: int, muted: bool) -> void:
	"""Set send mute state and sync to audio engine."""
	var send_config = get_send(target_channel_id)
	if not send_config:
		logger.warn("[%d] Send to channel %d not found" % [id, target_channel_id])
		return
	
	send_config.muted = muted
	
	# Sync to engine
	if _is_connected:
		AudioEngineOSC.send("/channel/%d/send/%d/mute" % [id, target_channel_id], [1 if muted else 0])
	
	send_changed.emit(target_channel_id, send_config)
	logger.info("[%d] Send to channel %d %s" % [id, target_channel_id, "muted" if muted else "unmuted"])


## Send a live note on/off (or other channel-voice) event to this channel's first device.
## `message` is a MIDI status nibble (e.g. MIDI_MESSAGE_NOTE_ON).
func send_midi_event(message: int, midi_channel: int, pitch: int, velocity: int) -> void:
	if not _is_connected:
		return
	AudioEngineOSC.send("/channel/%d/midi_event" % id, [
		id, message, midi_channel, pitch, velocity, Time.get_ticks_usec()
	])


## Send a live MIDI control change to this channel's first device.
func send_midi_cc(midi_channel: int, controller: int, value: int) -> void:
	if not _is_connected:
		return
	AudioEngineOSC.send("/channel/%d/midi_cc" % id, [
		id, midi_channel, controller, value, Time.get_ticks_usec()
	])


func get_send(target_channel_id: int) -> SendConfig:
	"""Get send configuration for a target channel."""
	for send in send_channels:
		if send.target_channel_id == target_channel_id:
			return send
	return null


# ============================================================================
# OSC CALLBACKS
# ============================================================================

func _on_peak_received(values) -> void:
	"""Handle incoming peak and RMS meter data from audio engine."""
	if values is Array and values.size() >= 4:
		peak_left = values[0] as float
		peak_right = values[1] as float
		rms_left = values[2] as float
		rms_right = values[3] as float
		peak_updated.emit(peak_left, peak_right, rms_left, rms_right)


# ============================================================================
# TRACK ROUTING MANAGEMENT
# ============================================================================

func register_track(track: Track) -> void:
	"""Register a track that routes to this channel."""
	if track not in routed_tracks:
		routed_tracks.append(track)
		logger.info("[%d] Track '%s' registered (routes to this channel)" % [id, track.name])


func unregister_track(track: Track) -> void:
	"""Unregister a track that no longer routes to this channel."""
	var idx = routed_tracks.find(track)
	if idx >= 0:
		routed_tracks.remove_at(idx)
		logger.info("[%d] Track '%s' unregistered" % [id, track.name])


## Push this channel's color onto every track that syncs from it.
func _sync_color_to_paired_tracks(new_color: Color) -> void:
	var notified: Dictionary = {}
	for track in routed_tracks:
		_apply_color_to_track(track, new_color, notified)
	var project := get_project()
	if project == null:
		return
	for track in project.tracks:
		if track and track.color_by_channel and track.default_channel_id == id:
			_apply_color_to_track(track, new_color, notified)


## Apply a color to one track if it hasn't already been notified this change.
func _apply_color_to_track(track: Track, new_color: Color, notified: Dictionary) -> void:
	if track == null or notified.has(track):
		return
	if not track.color_by_channel:
		return
	notified[track] = true
	track.apply_channel_color(new_color)


## Convert Device.DeviceType enum to string for OSC
func _get_device_type_string(device_type: Device.DeviceType) -> String:
	match device_type:
		Device.DeviceType.BuiltIn:
			return "builtin"
		Device.DeviceType.CLAP:
			return "clap"
		Device.DeviceType.LV2:
			return "lv2"
		_:
			return "builtin"


# ============================================================================
# DEVICE CHAIN MANAGEMENT
# ============================================================================

func add_device(device_instance: DeviceInstance, position: int = -1, parent: DeviceInstance = null) -> void:
	## Add a device to the channel root list or into a container parent.
	if parent and parent.device and parent.device.device_id == "sonara.builtin.drum_machine":
		if device_instance.slot_note < 0:
			device_instance.slot_note = parent.next_free_drum_note()
	var host: Array[DeviceInstance] = parent.children if parent else devices
	_ensure_device_name(device_instance, host)
	if position < 0 or position >= host.size():
		host.append(device_instance)
		position = host.size() - 1
	else:
		host.insert(position, device_instance)

	device_instance.channel_id = id
	device_instance.set_channel(self)
	device_instance.set_parent_device(parent)
	_reindex_host(host)

	var relay := _on_device_parameter_changed.bind(device_instance)
	if not device_instance.parameter_changed.is_connected(relay):
		device_instance.parameter_changed.connect(relay)

	if _is_connected:
		_send_add_device_osc(device_instance, parent)
		_sync_device_tree_to_engine(device_instance)
		device_instance.connect_to_engine()

	if parent:
		parent.child_added.emit(device_instance, position)
	else:
		device_added.emit(device_instance, position)
	logger.info("[%d] Device added at %s: %s" % [id, device_instance.osc_path(), device_instance.device.name])
	AuxReturnSync.on_device_added(get_project(), self, device_instance, parent)


func remove_device(position: int, parent: DeviceInstance = null) -> void:
	## Remove a device from the channel root list or from a container parent.
	var host: Array[DeviceInstance] = parent.children if parent else devices
	if position < 0 or position >= host.size():
		logger.warn("[%d] Invalid device position: %d" % [id, position])
		return

	var removed_device = host[position]
	var device_id = removed_device.device.device_id

	if _is_connected:
		removed_device.disconnect_from_engine()
		if parent:
			AudioEngineOSC.send(parent.osc_addr("remove_device"), [position])
		else:
			AudioEngineOSC.send("/channel/%d/remove_device" % id, [position])

	var relay := _on_device_parameter_changed.bind(removed_device)
	if removed_device.parameter_changed.is_connected(relay):
		removed_device.parameter_changed.disconnect(relay)

	var updated_relay := _on_device_parameters_updated.bind(removed_device)
	if removed_device.parameters_updated.is_connected(updated_relay):
		removed_device.parameters_updated.disconnect(updated_relay)

	host.remove_at(position)
	removed_device.set_parent_device(null)
	removed_device.set_channel(null)
	_reindex_host(host)

	if parent:
		parent.child_removed.emit(position, device_id)
	else:
		device_removed.emit(position, device_id)
	logger.info("[%d] Device removed: %s" % [id, device_id])
	AuxReturnSync.on_device_removed(get_project(), self, removed_device, parent)


## Remove a nested or root device by instance.
func remove_device_instance(device_instance: DeviceInstance) -> void:
	var parent: DeviceInstance = device_instance.get_parent_device()
	var host: Array[DeviceInstance] = parent.children if parent else devices
	var idx := host.find(device_instance)
	if idx >= 0:
		remove_device(idx, parent)


func move_device(from_position: int, to_position: int, parent: DeviceInstance = null) -> void:
	## Move a device within the channel root list or a container parent.
	var host: Array[DeviceInstance] = parent.children if parent else devices
	if from_position < 0 or from_position >= host.size():
		logger.warn("[%d] Invalid from_position: %d" % [id, from_position])
		return
	if to_position < 0 or to_position >= host.size():
		logger.warn("[%d] Invalid to_position: %d" % [id, to_position])
		return
	if from_position == to_position:
		return

	for device_inst in host:
		device_inst.disconnect_from_engine()

	var device_instance = host[from_position]
	host.remove_at(from_position)
	host.insert(to_position, device_instance)
	_reindex_host(host)

	if _is_connected:
		if parent:
			AudioEngineOSC.send(parent.osc_addr("move_device"), [from_position, to_position])
		else:
			AudioEngineOSC.send("/channel/%d/move_device" % id, [from_position, to_position])
		for device_inst in host:
			device_inst.connect_to_engine()

	if parent:
		parent.child_moved.emit(from_position, to_position)
	else:
		device_moved.emit(from_position, to_position)
	logger.info("[%d] Device moved from %d to %d: %s" % [id, from_position, to_position, device_instance.device.name])
	AuxReturnSync.on_device_moved(get_project(), self, parent)


func _reindex_host(host: Array[DeviceInstance]) -> void:
	## Keep child `position` in sync with array order.
	for i in range(host.size()):
		host[i].position = i


## Give `inst` a sibling-unique name on `host` (type name by default).
func _ensure_device_name(inst: DeviceInstance, host: Array[DeviceInstance]) -> void:
	if inst == null:
		return
	var fallback := inst.device.name if inst.device and not inst.device.name.is_empty() else "Device"
	var existing: PackedStringArray = []
	for d in host:
		if d != inst:
			existing.append(d.name)
	var desired := inst.name if not inst.name.is_empty() else fallback
	inst.name = DeviceNaming.unique_in(existing, desired, fallback)


func _send_add_device_osc(device_instance: DeviceInstance, parent: DeviceInstance) -> void:
	## Tell the engine to create this device at its current parent/position.
	var active = 1 if device_instance.active else 0
	var enabled = 1 if device_instance.enabled else 0
	var device_type = _get_device_type_string(device_instance.device.device_type)
	var args = [
		device_instance.device.device_id,
		device_instance.position,
		active,
		enabled,
		device_type,
		device_instance.device.plugin_path
	]
	if parent:
		AudioEngineOSC.send(parent.osc_addr("add_device"), args)
	else:
		AudioEngineOSC.send("/channel/%d/add_device" % id, args)


func _sync_device_tree_to_engine(device_instance: DeviceInstance) -> void:
	## Sync parameters, file, slots, and nested children after the engine has the device.
	device_instance.sync_to_engine()
	# Bind the DeviceInstance itself, not its position: position drifts when
	# devices are reordered, which would otherwise leave listeners refreshing
	# the wrong device (and would never compare equal for the is_connected
	# guard below, silently piling up duplicate connections).
	var updated_relay := _on_device_parameters_updated.bind(device_instance)
	if not device_instance.parameters_updated.is_connected(updated_relay):
		device_instance.parameters_updated.connect(updated_relay)
	if device_instance.device.device_type != Device.DeviceType.BuiltIn:
		AudioEngineOSC.send(device_instance.osc_addr("get_parameters"), [])
	if device_instance.loaded_file_path != "":
		device_instance.load_file(device_instance.loaded_file_path)
	device_instance.sync_slot_to_engine()
	for child in device_instance.children:
		_send_add_device_osc(child, device_instance)
		_sync_device_tree_to_engine(child)


func get_device(position: int) -> DeviceInstance:
	"""Get device at specified position, or null if invalid."""
	if position >= 0 and position < devices.size():
		return devices[position]
	return null


func get_device_count() -> int:
	"""Get number of devices on this channel."""
	return devices.size()


## Depth-first search for a device instance by id on this channel.
func find_device_by_id(instance_id: String) -> DeviceInstance:
	if instance_id.is_empty():
		return null
	return _find_device_by_id_in(devices, instance_id)


## Walk `host` and nested children for `instance_id`.
func _find_device_by_id_in(host: Array[DeviceInstance], instance_id: String) -> DeviceInstance:
	for d in host:
		if d and d.id == instance_id:
			return d
		var nested := _find_device_by_id_in(d.children, instance_id)
		if nested:
			return nested
	return null


func _wire_loaded_device(device_instance: DeviceInstance, parent: DeviceInstance) -> void:
	## Restore parent links, positions, and channel ids after project load.
	device_instance.channel_id = id
	device_instance.set_channel(self)
	device_instance.set_parent_device(parent)
	var host: Array[DeviceInstance] = parent.children if parent else devices
	var idx := host.find(device_instance)
	if idx >= 0:
		device_instance.position = idx
	_ensure_device_name(device_instance, host)
	for child in device_instance.children:
		_wire_loaded_device(child, device_instance)


# ============================================================================
# PRIVATE CALLBACKS
# ============================================================================

func _on_device_parameter_changed(param_id: int, value: float, device_instance: DeviceInstance) -> void:
	"""Handle parameter change from a device instance.

	NOTE: We do NOT send to engine here - DeviceInstance.set_parameter_normalized()
	already handles sending. This callback only relays the signal for UI notifications.
	Sending here would create a feedback loop with engine echoes.
	"""
	# Relay signal for UI notifications (other UI components may listen to Channel's signal).
	# Carries the DeviceInstance itself (not its position) so listeners aren't left
	# pointing at a stale slot after the device chain is reordered.
	device_parameter_changed.emit(device_instance, param_id, value)


# ============================================================================
# SERIALIZATION
# ============================================================================

# Serialize to JSON
func to_json() -> Dictionary:
	var data := JsonFields.write(self, JSON_FIELDS)
	data.merge({
		"id": id,
		"color": Utils.color_to_json(color),
		"channel_type": ChannelType.keys()[channel_type],
		"pan_mode": PanMode.keys()[pan_mode],
		"note_map_mode": NoteMapMode.keys()[note_map_mode],
		"note_map": note_map.to_json() if note_map else null,
		"child_channel_ids": child_channel_ids.duplicate(),
		"send_channels": send_channels.map(func(s): return s.to_json()),
		"devices": devices.map(func(d): return d.to_json()),
	})
	return data


## Plain fields copied by JsonFields; defaults come from the initializers and _init().
const JSON_FIELDS: Array[String] = [
	"name", "order", "device_output_id", "volume", "pan", "pan_left", "pan_right",
	"mute", "solo", "phase_invert", "output_channel_id", "parent_channel_id",
	"is_children_expanded", "aux_bus_index", "aux_pad_note", "midi_input_device", "record_armed",
	"drum_view",
]


# Deserialize from JSON
static func from_json(data: Dictionary) -> Channel:
	var channel_id = data.get("id", -1)
	var channel = Channel.new(channel_id)

	JsonFields.read(channel, data, JSON_FIELDS)
	channel.color = Utils.color_from_json(data.get("color"), channel.color)
	channel.channel_type = ChannelType.get(str(data.get("channel_type", "")), channel.channel_type)
	channel.pan_mode = PanMode.get(str(data.get("pan_mode", "")), channel.pan_mode)
	# A project saved before note maps existed has no key, so it lands on AUTO (REQ-012).
	channel.note_map_mode = NoteMapMode.get(str(data.get("note_map_mode", "")), channel.note_map_mode)
	if data.get("note_map") is Dictionary:
		channel.note_map = NoteMap.from_json(data["note_map"])
	channel.child_channel_ids.assign(data.get("child_channel_ids", []))

	# Load send_channels
	for send_data in data.get("send_channels", []):
		if send_data is Dictionary:
			var send_config = SendConfig.from_json(send_data)
			channel.send_channels.append(send_config)
	
	# Load devices (do NOT use add_device - that would sync to engine prematurely)
	# Devices will be synced to engine when channel.connect_to_engine() is called
	for device_data in data.get("devices", []):
		if device_data is Dictionary:
			var device_instance = DeviceInstance.from_json(device_data)
			if device_instance:
				channel.devices.append(device_instance)
				channel._wire_loaded_device(device_instance, null)
				device_instance.parameter_changed.connect(
					channel._on_device_parameter_changed.bind(device_instance)
				)
			else:
				# Device not found - skip it but log
				var device_id = device_data.get("device_id", "unknown")
				logger.warn("Skipping missing device: %s (run Edit > Scan Plugins)" % device_id)

	return channel


# ============================================================================
# DEVICE PARAMETER MANAGEMENT
# ============================================================================

## Handle when a device's parameters are updated (forwarded from DeviceInstance)
func _on_device_parameters_updated(device_instance: DeviceInstance) -> void:
	"""Called when a device's parameter list changes (e.g., SFZ file loaded)."""
	logger.info("[%d] Device %d parameters updated" % [id, device_instance.position])
	device_parameters_updated.emit(device_instance)
