@tool
class_name TrackItem extends PanelContainer

@export var bg_color := Color.CORNFLOWER_BLUE:
	set(c):
		bg_color = c
		queue_redraw()

# UI References
@export var volumeter: Volumeter
@export var label: SmartLineEdit
@export var arm_toggle: Button
@export var solo_toggle: Button 
@export var mute_toggle: Button

# at the bottom, a drop zone
@export var drop_zone: DropZone

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
		
		# Connect label (SmartLineEdit) for track name changes
		if label:
			label.value_changed.connect(_on_label_value_changed)
		
		# Set up drop zone
		if drop_zone:
			# Filter to only accept TrackDrag data
			drop_zone.accepts_data = func(data): return data is TrackDrag
			drop_zone.drop_accepted.connect(_on_drop_zone_drop)

	queue_redraw()


func _enter_tree() -> void:
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var mouse = get_local_mouse_position()

	# Detect resize area at bottom edge
	if mouse.y >= size.y - 4:
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
		track.parent_changed.connect(_on_track_parent_changed)

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
	size.y = track.height
	
	# Update label
	if label:
		label.set_value(track.name)
	
	# Update toggles
	if arm_toggle:
		arm_toggle.set_pressed_no_signal(track.armed)
	if solo_toggle:
		solo_toggle.set_pressed_no_signal(track.solo)
	if mute_toggle:
		mute_toggle.set_pressed_no_signal(track.muted)

	# Apply track color to background
	_update_track_bg_color()
	
	# Apply nesting level indentation
	_update_nesting_indent()

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

func _update_track_bg_color() -> void:
	"""Update the background color of the track item to the track's track_color."""
	var stylebox: StyleBoxFlat = get_theme_stylebox("panel")
	stylebox.bg_color = track.track_color


func _on_track_height_changed(new_height: int) -> void:
	"""React to track height changes (synced from other sources like TimelineTrack resize)."""
	custom_minimum_size.y = new_height


func _on_track_channel_id_changed(new_channel_id: int) -> void:
	"""React to track's channel routing change."""
	print("[TrackItem] Track channel ID changed to: ", new_channel_id)
	_unbind_from_channel()
	_bind_to_track_channel()


func _on_track_parent_changed(_new_parent_id: int) -> void:
	"""React to track parent changes - update nesting indent."""
	_update_nesting_indent()

func _on_track_color_changed(_c : Color) -> void:
	"""React to track color changes - update background color."""
	_update_track_bg_color()


func _update_nesting_indent() -> void:
	"""Apply left margin based on track's nesting level by modifying StyleBox."""
	
	var nesting_level = track.get_nesting_level(current_project)
	var indent_pixels = nesting_level * 12
	
	# Get the panel stylebox and modify its left margin
	var stylebox: StyleBoxFlat = get_theme_stylebox("panel")
	
	# Set the left content margin for indentation
	stylebox.border_width_left = indent_pixels
	
	# color the border = to parent track color
	var parent_track = current_project.get_track_by_id(track.parent_track_id)
	if parent_track:
		stylebox.border_color = parent_track.track_color
	
	print("[TrackItem] Track '", track.name, "' nesting level: ", nesting_level, " indent: ", indent_pixels, "px")


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


func _on_label_value_changed(new_value: String) -> void:
	"""Update track name when label is edited."""
	if track:
		track.name = new_value
		print("[TrackItem] Track name changed to: ", new_value)


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


# ============================================================================
# DRAG AND DROP
# ============================================================================

func _get_drag_data(_at_position: Vector2) -> Variant:
	"""Start dragging this track."""
	if not track or Engine.is_editor_hint():
		return null
	
	# Create drag preview
	var preview = _create_drag_preview()
	
	# Create drag data
	var drag_data = TrackDrag.new(self, track, preview)
	set_drag_preview(preview)
	
	print("[TrackItem] Started dragging track: ", track.name)
	return drag_data


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	"""Check if we can accept a track drop for foldering."""
	if not data is TrackDrag or not track:
		return false
	
	var drag_data = data as TrackDrag
	
	# Can't drop on self
	if drag_data.track == track:
		return false
	
	# Can only drop on FOLDER tracks for foldering
	if track.type != Track.TrackType.FOLDER:
		return false
	
	# Can't make a folder a child of itself (circular reference check)
	if drag_data.track.type == Track.TrackType.FOLDER:
		if _would_create_circular_reference(drag_data.track):
			return false
	
	return true


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	"""Accept a track drop - add to folder."""
	if not data is TrackDrag or not current_project or not track:
		return
	
	var drag_data = data as TrackDrag
	drag_data.destination = self
	
	# Add dragged track to this folder
	current_project.add_track_to_folder(drag_data.track.id, track.id)
	
	print("[TrackItem] Added track '%s' to folder '%s'" % [drag_data.track.name, track.name])


func _on_drop_zone_drop(data: Variant) -> void:
	"""Handle drop on the drop zone - insert after this track."""
	if not data is TrackDrag or not current_project or not track:
		return
	
	var drag_data = data as TrackDrag
	
	# Get TrackList to handle reordering
	var track_list = _get_track_list()
	if track_list:
		track_list.insert_track_after(drag_data.track, track)
		print("[TrackItem] Requested insert '%s' after '%s'" % [drag_data.track.name, track.name])


func _create_drag_preview() -> Control:
	"""Create a visual preview for dragging."""
	var preview = PanelContainer.new()
	var label_node = Label.new()
	label_node.text = track.name
	label_node.add_theme_color_override("font_color", Color.WHITE)
	preview.add_child(label_node)
	
	# Style the preview
	var style = StyleBoxFlat.new()
	style.bg_color = track.color
	style.bg_color.a = 0.8
	style.bg_color.v = 0.5
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	preview.add_theme_stylebox_override("panel", style)
	
	# Set minimum size
	preview.custom_minimum_size = Vector2(size.x, 30)

	preview.z_index = 1000
	
	return preview


func _would_create_circular_reference(dragged_folder: Track) -> bool:
	"""Check if making this track a child of dragged_folder would create circular reference."""
	if not current_project or not track:
		return false
	
	# Walk up the parent chain from this track
	var current_parent_id = track.parent_track_id
	while current_parent_id >= 0:
		if current_parent_id == dragged_folder.id:
			return true  # Dragged folder is already an ancestor
		
		var parent = current_project.get_track_by_id(current_parent_id)
		if not parent:
			break
		current_parent_id = parent.parent_track_id
	
	return false


func _get_track_list() -> TrackList:
	"""Get the TrackList parent."""
	var node = get_parent()
	while node:
		if node is TrackList:
			return node as TrackList
		node = node.get_parent()
	return null
