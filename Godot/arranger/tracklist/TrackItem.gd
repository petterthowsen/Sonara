@tool
class_name TrackItem extends PanelContainer

## Header row for a single arranger track. Emits selection and context-menu requests.

static var logger := Log.make("TrackItem")

# Emitted when the track item is right-clicked
signal right_clicked(track: Track, mouse_position: Vector2)
## Request that TrackList update selection. additive = Ctrl/Cmd, range_select = Shift.
signal select_requested(track: Track, additive: bool, range_select: bool)
## Tab/Shift+Tab while renaming: apply the name and continue on the adjacent track.
signal rename_tab_requested(track: Track, reverse: bool)
## Disclosure arrow toggled: TrackList shows or hides this track's automation lane rows (REQ-014).
signal automation_disclosure_toggled(track: Track, expanded: bool)
## Lane-menu button pressed: TrackList pops up AutomationLaneMenu at this position (REQ-014).
signal automation_menu_requested(track: Track, mouse_position: Vector2)

@export var bg_color := Color.CORNFLOWER_BLUE:
	set(c):
		bg_color = c
		queue_redraw()

@export_group("Selection Style")
@export var unselected_brightness := 0.55
@export var unselected_saturation := 0.65
@export var selected_brightness := 1.05
@export var active_brightness := 1.25
@export var selected_outline_color := Color(1, 1, 1, 0.35)
@export var active_outline_color := Color(1, 1, 1, 0.9)

# UI References
@export var volumeter: Volumeter
@export var label: SmartLineEdit
@export var arm_toggle: Button
@export var solo_toggle: Button 
@export var mute_toggle: Button
@export var automation_toggle: Button
@export var automation_menu_button: Button

## Folder/group fold button (hidden for tracks without children).
@onready var foldout_toggle: Button = get_node_or_null("VBoxContainer/HBox/MarginContainer/HBox/FoldoutToggle")

# Data binding
var track: Track = null
var track_index: int = -1
var channel: Channel = null  # Channel that this track routes to
var current_project: Project = null  # Reference to project for channel lookup
var _parent_color_track: Track = null

# Selection visuals (owned by TrackList; this node only renders them)
var is_selected: bool = false
var is_active: bool = false

# Resizing
var is_resizing: bool = false
var resize_start_y: float = 0.0
var resize_start_height: int = 0
var resize_min_height: int = 30

func _ready():
	# Enable focus so TrackItem can receive input events properly
	focus_mode = Control.FOCUS_CLICK
	# Keep height at custom_minimum_size so extra space in the list does not
	# stretch tracks (that stretch fights separator-drag when the list scrolls).
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	
	# Connect UI signals
	if not Engine.is_editor_hint():

		if arm_toggle:
			arm_toggle.toggled.connect(_on_arm_toggled)
		if solo_toggle:
			solo_toggle.toggled.connect(_on_solo_toggled)
		if mute_toggle:
			mute_toggle.toggled.connect(_on_mute_toggled)
		if automation_toggle:
			automation_toggle.toggled.connect(_on_automation_toggled)
		if automation_menu_button:
			automation_menu_button.pressed.connect(_on_automation_menu_pressed)
		if foldout_toggle:
			foldout_toggle.toggled.connect(_on_foldout_toggled)

		# Connect volumeter signal for volume changes
		if volumeter:
			volumeter.volume_changed.connect(_on_volumeter_volume_changed)
		
		# Connect label (SmartLineEdit) for track name changes
		if label:
			label.value_changed.connect(_on_label_value_changed)
			label.tab_requested.connect(_on_label_tab_requested)
		
		# Buttons/label/meter sit on top of the header; Godot asks them about
		# drops, so they must forward TrackDrag or a release over Mute cancels.
		_forward_track_drops_from(self)

	queue_redraw()


## Redraw on resize; unbind on free (not _exit_tree: DockHost reparents the arranger).
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
	elif what == NOTIFICATION_PREDELETE:
		_unbind()


func _enter_tree() -> void:
	queue_redraw()


## Draw selected/active outlines on top of the panel stylebox.
func _draw() -> void:
	if Engine.is_editor_hint():
		return
	if not is_selected and not is_active:
		return
	var inset_left := 1.0
	var stylebox: StyleBoxFlat = get_theme_stylebox("panel") as StyleBoxFlat
	if stylebox:
		inset_left = float(stylebox.border_width_left) + 1.0
	var r := Rect2(inset_left, 1.0, size.x - inset_left - 1.0, size.y - 2.0)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	if is_active:
		draw_rect(r, active_outline_color, false, 2.0)
	else:
		draw_rect(r, selected_outline_color, false, 1.0)


func _gui_input(event: InputEvent) -> void:
	var mouse = get_local_mouse_position()
	
	# Handle right-click for context menu
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if track and not Engine.is_editor_hint():
			right_clicked.emit(track, get_global_mouse_position())
			accept_event()
			return

	# Left-click selects this header (Ctrl/Cmd = toggle, Shift = range).
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# Ignore if we're clicking the resize gutter (handled below)
		if mouse.y < size.y - 4:
			if track and not Engine.is_editor_hint():
				var mouse_event := event as InputEventMouseButton
				var additive := mouse_event.ctrl_pressed or mouse_event.meta_pressed
				var range_select := mouse_event.shift_pressed
				select_requested.emit(track, additive, range_select)
				accept_event()
				return

	# Detect resize area at bottom edge
	if mouse.y >= size.y - 4:
		mouse_default_cursor_shape = Control.CURSOR_VSIZE

		# Handle mouse down to start resizing
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and not is_resizing:
				is_resizing = true
				resize_start_y = get_global_mouse_position().y
				resize_start_height = track.height if track else int(custom_minimum_size.y)
				resize_min_height = _content_min_height()
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
		var new_height = max(resize_min_height, resize_start_height + int(delta_y))

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


## Minimum height from inner controls, ignoring the current custom_minimum_size (which would ratchet).
func _content_min_height() -> int:
	var inner := get_node_or_null("VBoxContainer") as Control
	var content_min := 30
	if inner:
		content_min = max(content_min, int(inner.get_combined_minimum_size().y))
	var stylebox := get_theme_stylebox("panel") as StyleBox
	if stylebox:
		content_min += int(stylebox.get_minimum_size().y)
	return content_min


func bind_to_track(t: Track, idx: int, project: Project = null) -> void:
	"""Bind this UI element to a Track data object and its associated channel."""
	logger.info("bind_to_track called: track=", t.name if t else "null", " project=", project)

	_unbind()

	track = t
	track_index = idx
	current_project = project

	# Connect to track signals
	if track:
		track.name_changed.connect(_on_track_name_changed)
		track.color_changed.connect(_on_track_color_changed)
		track.height_changed.connect(_on_track_height_changed)
		track.default_channel_id_changed.connect(_on_track_channel_id_changed)
		track.parent_changed.connect(_on_track_parent_changed)
		track.automation_expanded_changed.connect(_on_track_automation_expanded_changed)
		track.folder_expanded_changed.connect(_on_track_folder_expanded_changed)

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
	_update_automation_controls()
	_update_foldout_toggle()

	# Apply track color, selection styling, and nesting indent
	_update_header_style()
	_update_nesting_indent()

# ============================================================================
# CHANNEL BINDING AND SYNC
# ============================================================================

func _bind_to_track_channel() -> void:
	"""Look up and bind to the channel associated with this track (including folder buses)."""
	if track == null or current_project == null:
		logger.warn("Cannot bind to channel: track=", track, " project=", current_project)
		return

	channel = track.get_linked_channel()
	if channel:
		logger.info("Bound to channel ", channel.id, " (", channel.name, ")")
		channel.volume_changed.connect(_on_channel_volume_changed)
		channel.peak_updated.connect(_on_channel_peak_updated)
		channel.record_armed_changed.connect(_on_channel_record_armed_changed)
		channel.mute_changed.connect(_on_channel_mute_changed)
		channel.solo_changed.connect(_on_channel_solo_changed)
		if mute_toggle:
			mute_toggle.set_pressed_no_signal(channel.mute)
		if solo_toggle:
			solo_toggle.set_pressed_no_signal(channel.solo)
		if not channel.color_changed.is_connected(_on_channel_color_changed):
			channel.color_changed.connect(_on_channel_color_changed)
		_update_volumeter_from_channel()
		if arm_toggle:
			arm_toggle.set_pressed_no_signal(channel.record_armed)
		if volumeter:
			volumeter.visible = true
		return

	if track.default_channel_id < 0:
		# Unrouted track (folder, or one created via "New Track"): no strip to meter.
		logger.info("Track ", track.name, " has no channel; volumeter hidden")
	else:
		logger.warn("No valid channel found for track ", track.name, " (default_channel_id=", track.default_channel_id, ")")
	channel = null
	if volumeter:
		volumeter.visible = false
	# Unrouted: the track holds its own mute/solo (kept from its last strip).
	if mute_toggle:
		mute_toggle.set_pressed_no_signal(track.muted)
	if solo_toggle:
		solo_toggle.set_pressed_no_signal(track.solo)


## Disconnect from the bound track, its channel and its parent's color. Idempotent.
func _unbind() -> void:
	_unbind_from_channel()
	_bind_parent_color(null)
	if track:
		if track.name_changed.is_connected(_on_track_name_changed):
			track.name_changed.disconnect(_on_track_name_changed)
		if track.color_changed.is_connected(_on_track_color_changed):
			track.color_changed.disconnect(_on_track_color_changed)
		if track.height_changed.is_connected(_on_track_height_changed):
			track.height_changed.disconnect(_on_track_height_changed)
		if track.default_channel_id_changed.is_connected(_on_track_channel_id_changed):
			track.default_channel_id_changed.disconnect(_on_track_channel_id_changed)
		if track.parent_changed.is_connected(_on_track_parent_changed):
			track.parent_changed.disconnect(_on_track_parent_changed)
		if track.automation_expanded_changed.is_connected(_on_track_automation_expanded_changed):
			track.automation_expanded_changed.disconnect(_on_track_automation_expanded_changed)
		if track.folder_expanded_changed.is_connected(_on_track_folder_expanded_changed):
			track.folder_expanded_changed.disconnect(_on_track_folder_expanded_changed)
	track = null
	current_project = null


func _unbind_from_channel() -> void:
	"""Disconnect from current channel."""
	if channel == null:
		return

	if channel.volume_changed.is_connected(_on_channel_volume_changed):
		channel.volume_changed.disconnect(_on_channel_volume_changed)
	if channel.peak_updated.is_connected(_on_channel_peak_updated):
		channel.peak_updated.disconnect(_on_channel_peak_updated)
	if channel.record_armed_changed.is_connected(_on_channel_record_armed_changed):
		channel.record_armed_changed.disconnect(_on_channel_record_armed_changed)
	if channel.mute_changed.is_connected(_on_channel_mute_changed):
		channel.mute_changed.disconnect(_on_channel_mute_changed)
	if channel.solo_changed.is_connected(_on_channel_solo_changed):
		channel.solo_changed.disconnect(_on_channel_solo_changed)
	if channel.color_changed.is_connected(_on_channel_color_changed):
		channel.color_changed.disconnect(_on_channel_color_changed)

	channel = null


func _update_volumeter_from_channel() -> void:
	"""Sync volumeter display from channel data."""
	if channel == null or volumeter == null:
		return

	# Volumeter now works directly with dB values
	volumeter.set_volume_no_signal(channel.volume)
	volumeter.set_levels(max(channel.peak_left, channel.peak_right), max(channel.rms_left, channel.rms_right))


# ============================================================================
# TRACK SIGNAL CALLBACKS
# ============================================================================

## Update selected/active flags and refresh header styling.
func set_selection_state(selected: bool, active: bool) -> void:
	if is_selected == selected and is_active == active:
		return
	is_selected = selected
	is_active = active
	_update_header_style()
	queue_redraw()


func _update_track_bg_color() -> void:
	"""Update the background color of the track item to the track's track_color."""
	_update_header_style()


## Tint the header for unselected, selected, or active.
func _update_header_style() -> void:
	if track == null:
		return
	var stylebox: StyleBoxFlat = get_theme_stylebox("panel") as StyleBoxFlat
	if stylebox == null:
		return

	var c := Utils.display_color(track.color)
	if is_active:
		c.v = clampf(c.v * active_brightness, 0.0, 1.0)
		c.s = clampf(c.s * 1.05, 0.0, 1.0)
	elif is_selected:
		c.v = clampf(c.v * selected_brightness, 0.0, 1.0)
	else:
		c.v = clampf(c.v * unselected_brightness, 0.0, 1.0)
		c.s = clampf(c.s * unselected_saturation, 0.0, 1.0)
	stylebox.bg_color = c

	if label:
		label.modulate.a = 1.0 if (is_selected or is_active) else 0.78
		label.set_font_color(Utils.contrasting_text_color(c))


func _on_track_height_changed(new_height: int) -> void:
	"""React to track height changes (synced from other sources like TimelineTrack resize)."""
	custom_minimum_size.y = new_height
	size.y = new_height


func _on_track_channel_id_changed(new_channel_id: int) -> void:
	"""React to track's channel routing change."""
	logger.info("Track channel ID changed to: ", new_channel_id)
	_unbind_from_channel()
	_bind_to_track_channel()


func _on_track_parent_changed(_new_parent_id: int) -> void:
	"""React to track parent changes - update nesting indent."""
	_update_nesting_indent()


func _on_track_name_changed(new_name: String) -> void:
	"""React to track name changes - update label."""
	if label:
		label.set_value(new_name)


func _on_track_color_changed(_c : Color) -> void:
	"""React to track color changes - update background color."""
	_update_track_bg_color()


## Mixer channel color (folder bus or routed strip) keeps this header in sync.
func _on_channel_color_changed(_c: Color) -> void:
	_update_track_bg_color()


func _update_nesting_indent() -> void:
	"""Apply left margin based on track's nesting level by modifying StyleBox."""
	if track == null or current_project == null:
		return

	var nesting_level = track.get_nesting_level(current_project)
	var indent_pixels = nesting_level * 12
	
	# Get the panel stylebox and modify its left margin
	var stylebox: StyleBoxFlat = get_theme_stylebox("panel")
	
	# Set the left content margin for indentation
	stylebox.border_width_left = indent_pixels
	
	# color the border = to parent track color
	var parent_track = current_project.get_track_by_id(track.parent_track_id)
	_bind_parent_color(parent_track)
	if parent_track:
		stylebox.border_color = Utils.display_color(parent_track.color)
	
	logger.info("Track '", track.name, "' nesting level: ", nesting_level, " indent: ", indent_pixels, "px")


## Keep the folder indent border in sync when the parent track color changes.
func _bind_parent_color(parent_track: Track) -> void:
	if _parent_color_track == parent_track:
		return
	if _parent_color_track and _parent_color_track.color_changed.is_connected(_on_parent_color_changed):
		_parent_color_track.color_changed.disconnect(_on_parent_color_changed)
	_parent_color_track = parent_track
	if _parent_color_track and not _parent_color_track.color_changed.is_connected(_on_parent_color_changed):
		_parent_color_track.color_changed.connect(_on_parent_color_changed)


## Redraw indent when the parent folder/group color changes.
func _on_parent_color_changed(_c: Color) -> void:
	_update_nesting_indent()


# ============================================================================
# UI CALLBACKS - User interactions
# ============================================================================

func _on_arm_toggled(pressed: bool) -> void:
	if track:
		track.set_armed(pressed)

func _on_solo_toggled(pressed: bool) -> void:
	if track:
		track.set_solo(pressed)

func _on_mute_toggled(pressed: bool) -> void:
	if track:
		track.set_mute(pressed)


## Mixer (or anything else) muted the strip: follow it without writing back.
func _on_channel_mute_changed(value: bool) -> void:
	if mute_toggle:
		mute_toggle.set_pressed_no_signal(value)


func _on_channel_solo_changed(value: bool) -> void:
	if solo_toggle:
		solo_toggle.set_pressed_no_signal(value)


## Open or close this track's automation lane rows. TrackList owns the row bookkeeping; this
## header only reports the gesture.
func _on_automation_toggled(pressed: bool) -> void:
	if track:
		automation_disclosure_toggled.emit(track, pressed)


func _on_automation_menu_pressed() -> void:
	if track:
		automation_menu_requested.emit(track, get_global_mouse_position())


## Follow the model when the disclosure is changed elsewhere (the lane menu expands the track
## when a lane is created or re-checked).
func _on_track_automation_expanded_changed(_expanded: bool) -> void:
	_update_automation_controls()


## Reflect the track's disclosure state, and show the arrow as filled when lanes exist.
func _update_automation_controls() -> void:
	if track == null:
		return
	if automation_toggle:
		# ToggleIconButton.set_state: set_pressed_no_signal + icon sync in one, without
		# emitting `toggled` back at the model that's being reflected.
		automation_toggle.set_state(track.automation_expanded)
		automation_toggle.disabled = track.automation_lanes.is_empty()
		automation_toggle.tooltip_text = (
			"Show/hide automation lanes (%d)" % track.automation_lanes.size()
		)


func _on_label_value_changed(new_value: String) -> void:
	"""Update track name when label is edited."""
	if track:
		# Record the final (possibly suffixed) name so redo reapplies exactly that.
		var final_name := track.unique_name_for(new_value)
		HistoryUtil.execute_property("Rename Track", track, "set_name", track.name, final_name)
		# The setter emits nothing when the suffixed name equals the current one; show it anyway.
		if label:
			label.set_value(track.name)
		logger.info("Track name changed to: ", track.name)


## Forward Tab/Shift+Tab from the name field so TrackList can rename the next track.
func _on_label_tab_requested(reverse: bool) -> void:
	if track:
		rename_tab_requested.emit(track, reverse)


## Open the track name field for in-place editing.
func begin_rename() -> void:
	if label:
		label.start_editing()


# ============================================================================
# CHANNEL SIGNAL CALLBACKS
# ============================================================================

func _on_volumeter_volume_changed(db_volume: float) -> void:
	"""User adjusted volumeter - sync dB value to channel."""
	if channel == null:
		logger.warn("Volumeter changed but no channel bound")
		return

	logger.debug("Volumeter changed: dB=", db_volume)
	channel.set_volume(db_volume)


func _on_channel_volume_changed(db_volume: float) -> void:
	"""Channel volume changed externally - update volumeter display."""
	if volumeter == null:
		return

	# Volumeter now works directly with dB values
	volumeter.set_volume_no_signal(db_volume)


func _on_channel_peak_updated(peak_left: float, peak_right: float, rms_left: float, rms_right: float) -> void:
	"""Channel peak levels updated - update volumeter meter display."""
	if volumeter == null:
		return

	volumeter.set_levels(max(peak_left, peak_right), max(rms_left, rms_right))


## Keep the header arm button in sync when record-arm is changed elsewhere.
func _on_channel_record_armed_changed(armed: bool) -> void:
	if track:
		track.armed = armed
	if arm_toggle:
		arm_toggle.set_pressed_no_signal(armed)


# ============================================================================
# DRAG AND DROP
# ============================================================================

## Start dragging this track (or the current multi-selection). Nothing moves until the drop.
func _get_drag_data(_at_position: Vector2) -> Variant:
	if not track or Engine.is_editor_hint() or is_resizing:
		return null
	if get_local_mouse_position().y >= size.y - 4:
		return null

	var track_list := _get_track_list()
	var drag_tracks: Array[Track] = [track]
	if track_list:
		drag_tracks = track_list.get_tracks_for_drag(track)

	var preview = _create_drag_preview(drag_tracks)
	var drag_data = TrackDrag.new(self, track, preview, drag_tracks)
	set_drag_preview(preview)

	if track_list:
		track_list.begin_track_drag(drag_data)

	logger.info("Started dragging %d track(s) from: %s" % [drag_tracks.size(), track.name])
	return drag_data


## Let descendant controls accept the same track drop as this header.
func _forward_track_drops_from(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			(child as Control).set_drag_forwarding(Callable(), _can_drop_data, _drop_data)
		_forward_track_drops_from(child)


## Track drags resolve from the pointer in TrackList (see TrackDropTarget).
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not data is TrackDrag or not track:
		return false
	var track_list := _get_track_list()
	return track_list != null and track_list.can_drop_track_drag(data as TrackDrag)


## Commit a track drag through TrackList.
func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not data is TrackDrag:
		return
	var track_list := _get_track_list()
	if track_list:
		track_list.drop_track_drag(data as TrackDrag)


## Create a compact ghost that follows the cursor; the headers stay put until the drop.
func _create_drag_preview(drag_tracks: Array[Track] = []) -> Control:
	var preview = PanelContainer.new()
	var label_node = Label.new()
	var preview_bg := Utils.display_color(track.color)
	preview_bg.a = 0.85
	if drag_tracks.size() > 1:
		label_node.text = "%s + %d" % [track.name, drag_tracks.size() - 1]
	else:
		label_node.text = track.name
	Utils.apply_label_font_color(label_node, Utils.contrasting_text_color(preview_bg))
	preview.add_child(label_node)
	
	# Style the preview
	var style = StyleBoxFlat.new()
	style.bg_color = preview_bg
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	preview.add_theme_stylebox_override("panel", style)
	
	preview.custom_minimum_size = Vector2(minf(size.x, 160.0), 24)

	preview.z_index = 1000
	
	return preview


func _get_track_list() -> TrackList:
	"""Get the TrackList parent."""
	var node = get_parent()
	while node:
		if node is TrackList:
			return node as TrackList
		node = node.get_parent()
	return null


# ============================================================================
# FOLDING
# ============================================================================

## Show the fold button on folders and groups, pressed while children are shown.
func _update_foldout_toggle() -> void:
	if foldout_toggle == null or track == null:
		return
	foldout_toggle.visible = track.can_contain_tracks()
	if foldout_toggle is ToggleIconButton:
		(foldout_toggle as ToggleIconButton).set_state(track.is_folder_expanded)
	else:
		foldout_toggle.set_pressed_no_signal(track.is_folder_expanded)
	foldout_toggle.tooltip_text = "Hide child tracks" if track.is_folder_expanded else "Show child tracks"


func _on_foldout_toggled(pressed: bool) -> void:
	if track:
		track.is_folder_expanded = pressed


func _on_track_folder_expanded_changed(_expanded: bool) -> void:
	_update_foldout_toggle()
