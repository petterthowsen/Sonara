@tool
class_name TrackItem extends MarginContainer

@export var bg_color := Color.CORNFLOWER_BLUE:
	set(c):
		bg_color = c
		queue_redraw()

# UI References
@onready var volumeter: Volumeter = $HBox/Volumeter
@onready var label: Label = $HBox/MarginContainer/VBox/Top/Label
@onready var arm_toggle: Button = $HBox/MarginContainer/VBox/Top/Toggles/ArmToggle
@onready var solo_toggle: Button = $HBox/MarginContainer/VBox/Top/Toggles/SoloMute/SoloToggle
@onready var mute_toggle: Button = $HBox/MarginContainer/VBox/Top/Toggles/SoloMute/MuteToggle

# Data binding
var track: Track = null
var track_index: int = -1
var channel: Channel = null  # Channel that this track routes to
var current_project: Project = null  # Reference to project for channel lookup

# Resizing
var is_resizing: bool = false
var resize_start_y: float = 0.0
var resize_start_height: int = 0

func _ready():
	# Connect UI signals
	if not Engine.is_editor_hint():

		if arm_toggle:
			arm_toggle.toggled.connect(_on_arm_toggled)
		if solo_toggle:
			solo_toggle.toggled.connect(_on_solo_toggled)
		if mute_toggle:
			mute_toggle.toggled.connect(_on_mute_toggled)

		# Connect volumeter signal for volume changes
		if volumeter:
			volumeter.volume_changed.connect(_on_volumeter_volume_changed)

	queue_redraw()


func _draw() -> void:
	# draw bg
	draw_rect(Rect2(0, 0, size.x, size.y), bg_color, true, -1.0, true)
	
	# draw border
	draw_rect(Rect2(0, size.y - 1, size.x, 2), Color(0,0,0,0.5), true, -1.0, true)


func _gui_input(event: InputEvent) -> void:
	var mouse = get_local_mouse_position()

	# Detect resize area at bottom edge
	if mouse.y > size.y - 4:
		mouse_default_cursor_shape = Control.CURSOR_VSIZE

		# Handle mouse down to start resizing
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and not is_resizing:
				is_resizing = true
				resize_start_y = get_global_mouse_position().y
				resize_start_height = track.height if track else int(custom_minimum_size.y)
				accept_event()
			elif event.is_released() and is_resizing:
				is_resizing = false
				accept_event()
	else:
		mouse_default_cursor_shape = Control.CURSOR_ARROW


func _input(event: InputEvent) -> void:
	"""Handle resizing while dragging."""
	if is_resizing and event is InputEventMouseMotion:
		var current_y = get_global_mouse_position().y
		var delta_y = current_y - resize_start_y
		# Respect the TrackItem's minimum size based on its UI components
		var min_height = max(30, get_minimum_size().y)
		var new_height = max(min_height, resize_start_height + int(delta_y))

		if track:
			track.height = new_height
		else:
			custom_minimum_size.y = new_height

		accept_event()

	# Stop resizing if mouse is released
	if is_resizing and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_released():
			is_resizing = false
			accept_event()


func bind_to_track(t: Track, idx: int, project: Project = null) -> void:
	"""Bind this UI element to a Track data object and its associated channel."""
	print("[TrackItem] bind_to_track called: track=", t.name if t else "null", " project=", project)

	# Disconnect from old track if any
	if track:
		if track.color_changed.is_connected(_on_track_color_changed):
			track.color_changed.disconnect(_on_track_color_changed)
		if track.height_changed.is_connected(_on_track_height_changed):
			track.height_changed.disconnect(_on_track_height_changed)
		if track.default_channel_id_changed.is_connected(_on_track_channel_id_changed):
			track.default_channel_id_changed.disconnect(_on_track_channel_id_changed)

	# Disconnect from old channel if any
	_unbind_from_channel()

	track = t
	track_index = idx
	current_project = project

	# Connect to track signals
	if track:
		track.color_changed.connect(_on_track_color_changed)
		track.height_changed.connect(_on_track_height_changed)
		track.default_channel_id_changed.connect(_on_track_channel_id_changed)

	# Look up and bind to the track's channel
	_bind_to_track_channel()

	# Update UI from track data
	_update_from_track()

func _update_from_track() -> void:
	"""Update all UI elements from track data."""
	if track == null:
		return
	
	# Update height to match track height
	custom_minimum_size.y = track.height
	
	# Update label
	if label:
		label.text = track.name
	
	# Update toggles
	if arm_toggle:
		arm_toggle.set_pressed_no_signal(track.armed)
	if solo_toggle:
		solo_toggle.set_pressed_no_signal(track.solo)
	if mute_toggle:
		mute_toggle.set_pressed_no_signal(track.muted)

	# Apply track color to background
	_update_track_bg_color(track.color)

# ============================================================================
# CHANNEL BINDING AND SYNC
# ============================================================================

func _bind_to_track_channel() -> void:
	"""Look up and bind to the channel associated with this track."""
	if track == null or current_project == null:
		print("[TrackItem] Cannot bind to channel: track=", track, " project=", current_project)
		return

	print("[TrackItem] _bind_to_track_channel: track=", track.name, " default_channel_id=", track.default_channel_id)
	print("[TrackItem] Available channels: ", current_project.channels.size())
	for ch in current_project.channels:
		print("  - Channel ID: ", ch.id, " Name: ", ch.name)

	# Look up channel by track's default_channel_id
	if track.default_channel_id >= 0:
		for ch in current_project.channels:
			if ch.id == track.default_channel_id:
				channel = ch
				print("[TrackItem] Bound to channel ", channel.id, " (", channel.name, ")")
				# Connect to channel signals
				channel.volume_changed.connect(_on_channel_volume_changed)
				channel.peak_updated.connect(_on_channel_peak_updated)
				# Sync UI from channel data
				_update_volumeter_from_channel()
				return

	# No valid channel found
	print("[TrackItem] No valid channel found for track ", track.name, " (default_channel_id=", track.default_channel_id, ")")
	channel = null


func _unbind_from_channel() -> void:
	"""Disconnect from current channel."""
	if channel == null:
		return

	if channel.volume_changed.is_connected(_on_channel_volume_changed):
		channel.volume_changed.disconnect(_on_channel_volume_changed)
	if channel.peak_updated.is_connected(_on_channel_peak_updated):
		channel.peak_updated.disconnect(_on_channel_peak_updated)

	channel = null


func _update_volumeter_from_channel() -> void:
	"""Sync volumeter display from channel data."""
	if channel == null or volumeter == null:
		return

	# Volumeter now works directly with dB values
	volumeter.set_volume_no_signal(channel.volume)
	volumeter.peak = max(channel.peak_left, channel.peak_right)


# ============================================================================
# TRACK SIGNAL CALLBACKS
# ============================================================================

func _on_track_color_changed(new_color: Color) -> void:
	"""React to track color changes."""
	_update_track_bg_color(new_color)


func _on_track_height_changed(new_height: int) -> void:
	"""React to track height changes (synced from other sources like TimelineTrack resize)."""
	custom_minimum_size.y = new_height


func _on_track_channel_id_changed(new_channel_id: int) -> void:
	"""React to track's channel routing change."""
	print("[TrackItem] Track channel ID changed to: ", new_channel_id)
	_unbind_from_channel()
	_bind_to_track_channel()


func _update_track_bg_color(color: Color) -> void:
	"""Update background color from track color."""
	if color != Color.WHITE:
		bg_color = color
		bg_color.v = clamp(bg_color.v, 0.1, 0.7)
	else:
		# Fallback to a neutral dark color if no color set
		bg_color = Color.from_string("#444444", Color.WHITE)


# ============================================================================
# UI CALLBACKS - User interactions
# ============================================================================

func _on_arm_toggled(pressed: bool) -> void:
	if track:
		track.armed = pressed

func _on_solo_toggled(pressed: bool) -> void:
	if track:
		track.solo = pressed

func _on_mute_toggled(pressed: bool) -> void:
	if track:
		track.muted = pressed


# ============================================================================
# CHANNEL SIGNAL CALLBACKS
# ============================================================================

func _on_volumeter_volume_changed(db_volume: float) -> void:
	"""User adjusted volumeter - sync dB value to channel."""
	if channel == null:
		print("[TrackItem] Volumeter changed but no channel bound")
		return

	print("[TrackItem] Volumeter changed: dB=", db_volume)
	channel.set_volume(db_volume)


func _on_channel_volume_changed(db_volume: float) -> void:
	"""Channel volume changed externally - update volumeter display."""
	if volumeter == null:
		return

	# Volumeter now works directly with dB values
	volumeter.set_volume_no_signal(db_volume)


func _on_channel_peak_updated(left: float, right: float) -> void:
	"""Channel peak levels updated - update volumeter meter display."""
	if volumeter == null:
		return

	volumeter.peak = max(left, right)
