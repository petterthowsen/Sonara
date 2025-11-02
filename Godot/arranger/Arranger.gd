# Arranger.gd
# 
# Arranger is a vbox, containing:
# - ArrangeTop header containing the header panel of both tracks and the timeline
#   - TracklistHeader contains tools/buttons for track and/or timeline functions
#   - TimelineHeader contains musical ruler, time ruler, loop region, playback start position (arrow icon), chord track etc.
# - ScrollContainer with a HSplit (tracks on the left, timeline on the right)
# - ArrangerBottom with auxiliary tools/buttons/status
# 
# Notes:
# TracksPanel width
#   The width of the TracksPanel is customizable (via HSplit)
#   Width of TracksPanel is synced to the TracklistHeader
#
# Track Height
#  Tracks can have independently varying heights, these must be synced to the height of visual track grid in the timeline (and midi/audio clips)
class_name Arranger extends VBoxContainer

# ArrangerTop
@onready var arrange_top: PanelContainer = $VSplitContainer/ArrangeTop
@onready var tracklist_header: PanelContainer = $VSplitContainer/ArrangeTop/HBox/TracklistHeader
@onready var timeline_header: PanelContainer = $VSplitContainer/ArrangeTop/HBox/TimelineHeader

@onready var add_track_button: Button = $VSplitContainer/ArrangeTop/HBox/TracklistHeader/Buttons/AddTrackButton
@onready var add_folder_button: Button = $VSplitContainer/ArrangeTop/HBox/TracklistHeader/Buttons/AddFolderButton

@onready var v_split : VSplitContainer = $VSplitContainer

# Vertical scrolling container
@onready var v_scroll: ScrollContainer = $VSplitContainer/VScroll
@onready var h_split: HSplitContainer = $VSplitContainer/VScroll/HSplit
@onready var tracks_panel: PanelContainer = $VSplitContainer/VScroll/HSplit/TracksPanel
@onready var track_list: VBoxContainer = $VSplitContainer/VScroll/HSplit/TracksPanel/VBox/TrackList

# Syncing flag to prevent feedback loops
var _syncing_split: bool = false

@onready var timeline_panel: PanelContainer = $VSplitContainer/VScroll/HSplit/TimelinePanel
@onready var h_scroll: ScrollContainer = $VSplitContainer/VScroll/HSplit/TimelinePanel/HScroll
@onready var timeline: Timeline = $VSplitContainer/VScroll/HSplit/TimelinePanel/HScroll/Timeline
@onready var ruler: Ruler = $VSplitContainer/ArrangeTop/HBox/TimelineHeader/VBox/Ruler
@onready var overlay: Control = $VSplitContainer/VScroll/HSplit/TimelinePanel/Overlay
@onready var playhead: ColorRect = $VSplitContainer/VScroll/HSplit/TimelinePanel/Overlay/Playhead

# ArrangerBottom
@onready var arranger_bottom: PanelContainer = $ArrangerBottom

# Panning state
var is_panning: bool = false
var pan_start_pos: Vector2 = Vector2.ZERO
var pan_start_h_scroll: float = 0.0
var pan_start_v_scroll: float = 0.0

# Smooth scrolling: 0 = instant, higher = smoother (0.1-0.3 recommended)
@export var scroll_smoothing: float = 0.5

# Scroll speeds
@export var scroll_speed_h: int = 50   # Horizontal scroll speed per wheel tick
@export var scroll_speed_v: int = 30   # Vertical scroll speed per wheel tick

# Zoom sensitivity: multiplier for zoom speed (higher = faster zoom)
@export var zoom_sensitivity_h: float = 1.1  # Horizontal zoom multiplier per scroll tick
@export var zoom_sensitivity_v: float = 1.1  # Vertical zoom multiplier per scroll tick (for track heights)

# Horizontal zoom limits (pixels per beat)
@export var zoom_min_pixels_per_beat: float = 8.0
@export var zoom_max_pixels_per_beat: float = 512.0

# Target scroll positions for smooth scrolling
var target_scroll_vertical: float = 0.0
var target_scroll_horizontal: float = 0.0

# Target zoom values for smooth zooming
var target_pixels_per_beat: float = 0.0  # Horizontal zoom target
var target_track_height: float = 0.0     # Vertical zoom target (average height)

# Active zoom flags (to prevent interference with manual resizing)
var _is_zooming_vertically: bool = false

# Current project reference
var current_project: Project = null

# Shared grid helper for timeline and ruler
var grid_helper: GridHelper = GridHelper.new()  # Default grid helper instance

var _timeline_tracks: Dictionary = {}   # Maps TimelineTrack to its corresponding Track

# Signal for multi-track selection changes
signal clips_selected(clips: Array[ClipInstance], multi_track: bool)

func _ready():
	# Initialize target scroll positions to current values
	target_scroll_vertical = v_scroll.scroll_vertical
	target_scroll_horizontal = h_scroll.scroll_horizontal
	
	# Initialize target zoom values
	target_pixels_per_beat = grid_helper.pixels_per_beat
	target_track_height = 80.0  # Default, will be updated when project loads

	# Connect add track button
	add_track_button.pressed.connect(_on_add_track_pressed)
	add_folder_button.pressed.connect(_on_add_folder_pressed)

	# Set up custom scroll handling by intercepting gui_input on scroll containers
	v_scroll.gui_input.connect(_on_scroll_container_input.bind(v_scroll))
	h_scroll.gui_input.connect(_on_scroll_container_input.bind(h_scroll))

	# Connect horizontal scroll to update ruler and playhead
	h_scroll.get_h_scroll_bar().value_changed.connect(_on_h_scroll_changed)

	# Connect HSplit dragging to sync with TracklistHeader width
	h_split.dragged.connect(_on_h_split_dragged)
	_on_h_split_dragged(h_split.split_offset)

	# Connect to Timeline signals
	timeline.clips_selected.connect(_on_timeline_clips_selected)

	# Connect to Editor signals for project lifecycle, playhead, and musical properties
	Sonara.editor.project_activated.connect(_on_project_activated)
	Sonara.editor.project_closed.connect(_on_project_closed)
	Sonara.editor.playhead_moved.connect(_on_playhead_moved)
	Sonara.editor.time_signature_changed.connect(_on_time_signature_changed)
	
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	visibility_changed.connect(_on_visibility_changed)

	# Initial ruler and playhead update
	_update_ruler()
	_update_playhead_position()


func _on_mouse_entered() -> void:
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return
	
	print("[Arranger] mouse entered")
	grab_click_focus()
	

func _on_mouse_exited() -> void:
	release_focus()


func _on_visibility_changed() -> void:
	print("[Arranger] visibility changed")
	if is_visible_in_tree():
		grab_click_focus()
		# When becoming visible after being hidden (e.g., mixer view active during project load),
		# force a refresh to recompute timeline width, clip positions and redraw everything.
		_call_visible_refresh()
	else:
		release_focus()


func _call_visible_refresh() -> void:
	"""Defer a full visual refresh to the next frame to ensure layout sizes are valid."""
	call_deferred("_refresh_after_visible")


func _refresh_after_visible() -> void:
	"""Recompute timeline width, update clip positions and redraw after Arranger becomes visible."""
	# Ensure scroll/zoom propagated and trigger timeline updates
	timeline.set_scroll_offset(h_scroll.scroll_horizontal)
	timeline.set_zoom(grid_helper.pixels_per_beat)
	
	# Force full layout refresh on the timeline to fix zero-height clips after being hidden
	if timeline:
		timeline.refresh_layout()
	
	# Update overlays
	_update_ruler()
	_update_playhead_position()


func _process(delta: float) -> void:
	"""Update ruler, playhead, smooth scrolling, and smooth zooming every frame."""
	# Smooth scroll and zoom interpolation
	if scroll_smoothing > 0:
		var lerp_factor = 1.0 - pow(scroll_smoothing, delta * 60.0)
		
		# Lerp vertical scroll
		v_scroll.scroll_vertical = int(lerp(float(v_scroll.scroll_vertical), target_scroll_vertical, lerp_factor))
		
		# Lerp horizontal scroll
		var new_h_scroll = lerp(float(h_scroll.scroll_horizontal), target_scroll_horizontal, lerp_factor)
		h_scroll.scroll_horizontal = int(new_h_scroll)
		grid_helper.scroll_position = new_h_scroll
		
		# Lerp horizontal zoom (pixels per beat)
		var current_ppb = grid_helper.pixels_per_beat
		var new_ppb = lerp(current_ppb, target_pixels_per_beat, lerp_factor)
		if abs(new_ppb - target_pixels_per_beat) > 0.01:  # Only update if difference is significant
			timeline.set_zoom(new_ppb)
		
		# Lerp vertical zoom (track heights) - only if actively zooming
		if _is_zooming_vertically and current_project and current_project.tracks.size() > 0:
			# Calculate current average height
			var total_height = 0.0
			for track in current_project.tracks:
				total_height += track.height
			var current_avg_height = total_height / current_project.tracks.size()
			
			# Lerp to target
			var new_avg_height = lerp(current_avg_height, target_track_height, lerp_factor)
			
			# Only update if difference is significant
			if abs(new_avg_height - target_track_height) > 0.5:
				_apply_track_heights(int(new_avg_height))
			else:
				# Stop zooming when we've reached the target
				_is_zooming_vertically = false
	else:
		# Instant scrolling/zooming when smoothing is disabled
		v_scroll.scroll_vertical = int(target_scroll_vertical)
		h_scroll.scroll_horizontal = int(target_scroll_horizontal)
		grid_helper.scroll_position = target_scroll_horizontal
		
		# Instant zoom
		if abs(grid_helper.pixels_per_beat - target_pixels_per_beat) > 0.01:
			timeline.set_zoom(target_pixels_per_beat)
		
		# Instant vertical zoom - only if actively zooming
		if _is_zooming_vertically and current_project and current_project.tracks.size() > 0:
			var total_height = 0.0
			for track in current_project.tracks:
				total_height += track.height
			var current_avg_height = total_height / current_project.tracks.size()
			if abs(current_avg_height - target_track_height) > 0.5:
				_apply_track_heights(int(target_track_height))
			else:
				_is_zooming_vertically = false
	
	_update_ruler()
	_update_playhead_position()

# ============================================================================
# INPUT HANDLING
# ============================================================================

func _on_scroll_container_input(event: InputEvent, scroll_container: ScrollContainer) -> void:
	"""Intercept scroll events on scroll containers."""
	if event is InputEventMouseButton and event.pressed:
		var is_scroll_up = false
		
		# Detect scroll wheel
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			is_scroll_up = true
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			is_scroll_up = false
		else:
			return  # Not a scroll event
		
		# Handle scroll/zoom based on modifiers
		# Shift + Scroll = Horizontal zoom
		if event.shift_pressed:
			if grid_helper:
				# Calculate the zoom point - use cursor position for better UX
				# Get cursor position relative to the h_scroll viewport
				var viewport_width = h_scroll.size.x
				var local_mouse_x = h_scroll.get_local_mouse_position().x

				# Clamp to visible viewport bounds
				var zoom_point_x = clamp(local_mouse_x, 0.0, viewport_width)

				# Convert to timeline pixel position (scroll_offset + local position)
				var zoom_pixel_x = h_scroll.scroll_horizontal + zoom_point_x

				# Check if scroll position is close to origin (within 1 beat worth of pixels)
				var one_beat_pixels = grid_helper.pixels_per_beat
				var near_origin = h_scroll.scroll_horizontal < one_beat_pixels

				# Calculate target zoom using zoom_sensitivity_h
				var zoom_factor = zoom_sensitivity_h if is_scroll_up else (1.0 / zoom_sensitivity_h)
				target_pixels_per_beat = clamp(grid_helper.pixels_per_beat * zoom_factor, zoom_min_pixels_per_beat, zoom_max_pixels_per_beat)

				# Adjust scroll position to keep content under cursor
				# Note: scroll adjustment needs to account for the eventual zoom change
				# For now, we adjust based on target zoom to prevent drift
				if near_origin:
					# Lock to origin - keep scroll at 0
					target_scroll_horizontal = 0
				else:
					# Calculate expected position after zoom
					var zoom_ratio = target_pixels_per_beat / grid_helper.pixels_per_beat
					var new_content_x = zoom_pixel_x * zoom_ratio
					var new_scroll = new_content_x - zoom_point_x
					target_scroll_horizontal = max(0.0, new_scroll)

				# Update ruler when zoom changes
				_update_ruler()
				scroll_container.accept_event()
		# Ctrl + Scroll = Vertical zoom (track heights)
		elif event.ctrl_pressed:
			_zoom_tracks_vertically(is_scroll_up)
			scroll_container.accept_event()
		# Alt + Scroll = Horizontal scroll
		elif event.alt_pressed:
			if h_scroll:
				var scroll_delta = -scroll_speed_h if is_scroll_up else scroll_speed_h
				target_scroll_horizontal = max(0, target_scroll_horizontal + scroll_delta)
				scroll_container.accept_event()
		# Normal Scroll = Vertical scroll
		else:
			if v_scroll:
				var scroll_delta = -scroll_speed_v if is_scroll_up else scroll_speed_v
				target_scroll_vertical = max(0, target_scroll_vertical + scroll_delta)
				scroll_container.accept_event()

func _on_h_scroll_changed(_value: float) -> void:
	"""Update ruler and playhead when horizontal scroll changes."""
	_update_ruler()
	_update_playhead_position()

func _on_playhead_moved(_ticks: int) -> void:
	"""Update playhead visual position when playhead moves."""
	_update_playhead_position()

func _on_time_signature_changed(numerator: int, denominator: int) -> void:
	"""Update grid helper when time signature changes."""
	
	grid_helper.time_numerator = numerator
	grid_helper.time_denominator = denominator


func _gui_input(event: InputEvent) -> void:
	_handle_input(event)


func _unhandled_input(event: InputEvent) -> void:
	var visible_in_tree = is_visible_in_tree()
	if not visible_in_tree:
		return

	var mouse_position = get_global_mouse_position()
	var timeline_has_point = timeline.get_global_rect().has_point(mouse_position)
	if not timeline_has_point:
		return
	_handle_input(event)


func _handle_input(event: InputEvent) -> void:
	"""Handle middle mouse button panning (only if not handled by child controls)."""
	if event is InputEventKey and event.pressed:
		if event.is_action_pressed("ui_copy"):
			timeline.copy_selection_to_clipboard()
			accept_event()
		elif event.is_action_pressed("ui_cut"):
			timeline.cut_selection_to_clipboard()
			accept_event()
		elif event.is_action_pressed("ui_paste"):
			timeline.paste_clipboard()
			accept_event()
		elif event.is_action_pressed("ui_duplicate"):
			timeline.duplicate_selection()
			accept_event()
		elif timeline.clip_selection_manager.has_selection():
			if event.is_action_pressed("ui_left"):
				timeline.move_selection_by_ticks(-timeline.get_move_step_ticks())
				accept_event()
			elif (event.keycode == KEY_RIGHT or event.is_action_pressed("ui_right")):
				timeline.move_selection_by_ticks(timeline.get_move_step_ticks())
				accept_event()
			elif (event.keycode == KEY_UP or event.is_action_pressed("ui_up")):
				timeline.move_selection_by_tracks(-1)
				accept_event()
			elif (event.keycode == KEY_DOWN or event.is_action_pressed("ui_down")):
				timeline.move_selection_by_tracks(1)
				accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			is_panning = true
			pan_start_pos = event.global_position
			pan_start_h_scroll = h_scroll.scroll_horizontal
			pan_start_v_scroll = v_scroll.scroll_vertical
			accept_event()
		else:
			is_panning = false
			accept_event()
		
	elif event is InputEventMouseMotion and is_panning:
		var current_pos = event.global_position
		var delta = current_pos - pan_start_pos
		# Direct scroll for panning (bypass smoothing for responsive feel)
		var new_h_scroll = int(pan_start_h_scroll - delta.x)
		h_scroll.scroll_horizontal = new_h_scroll
		target_scroll_horizontal = new_h_scroll
		grid_helper.scroll_position = new_h_scroll
		
		var new_v_scroll = int(pan_start_v_scroll - delta.y)
		v_scroll.scroll_vertical = new_v_scroll
		target_scroll_vertical = new_v_scroll
		accept_event()


func _zoom_tracks_vertically(zoom_in: bool) -> void:
	"""Zoom tracks vertically by adjusting their heights (smoothly)."""
	if not current_project or current_project.tracks.size() == 0:
		return

	# Calculate average track height
	var total_height = 0.0
	for track in current_project.tracks:
		total_height += track.height
	var avg_height = total_height / current_project.tracks.size()

	# Calculate new target height using zoom_sensitivity_v
	var zoom_factor = zoom_sensitivity_v if zoom_in else (1.0 / zoom_sensitivity_v)
	var new_height = avg_height * zoom_factor

	# Get minimum height from TrackItem (check first available TrackItem)
	var min_height = 30.0  # Fallback minimum
	if track_list:
		for child in track_list.get_children():
			if child is TrackItem:
				min_height = max(min_height, child.get_minimum_size().y)
				break

	# Clamp to reasonable bounds and set as target
	target_track_height = clamp(new_height, min_height, 200.0)
	
	# Enable vertical zoom interpolation
	_is_zooming_vertically = true


func _apply_track_heights(new_height: int) -> void:
	"""Apply the given height to all tracks (called during smooth zoom interpolation)."""
	if not current_project:
		return
	
	# Update all tracks to the new height
	for track in current_project.tracks:
		track.height = new_height

	# Force UI update by triggering track item refresh
	if track_list:
		for child in track_list.get_children():
			if child is TrackItem and child.track:
				child.custom_minimum_size.y = child.track.height


func _update_ruler() -> void:
	"""Update ruler with current scroll position."""
	
	# Update scroll position (ruler and timeline share the same grid_helper instance)
	grid_helper.scroll_position = h_scroll.scroll_horizontal


func _update_playhead_position() -> void:
	"""Update playhead visual position based on current playhead ticks."""
	# Convert playhead ticks to pixel position
	var playhead_pixels = grid_helper.ticks_to_pixels(Sonara.editor.playhead_ticks)
	
	# Account for horizontal scroll
	var scroll_offset = h_scroll.scroll_horizontal
	
	# set playhead position
	playhead.position.x = playhead_pixels - scroll_offset


# ============================================================================
# UI CALLBACKS
# ============================================================================

func _on_add_track_pressed() -> void:
	"""Create and add a new track with corresponding channel to the project."""
	if not current_project:
		push_warning("[Arranger] Cannot add track: No project active")
		return

	# Generate name based on track count
	var track_num = current_project.tracks.size() + 1
	var track_name = "Track %d" % track_num

	# Use Project's create_instrument_track convenience method
	# This creates both track and channel with proper linking (including random colors)
	var result = current_project.create_instrument_track(track_name)
	var new_track = result["track"] as Track
	var new_channel = result["channel"] as Channel

	# Set visual properties (channel color already set by project.create_channel())
	new_track.color = new_channel.color

	print("[Arranger] Added track '%s' (ID %d) with channel (ID %d)" % [track_name, new_track.id, new_channel.id])


func _on_add_folder_pressed() -> void:
	"""Create and add a new folder track with corresponding bus channel to the project."""
	if not current_project:
		push_warning("[Arranger] Cannot add folder: No project active")
		return

	# Count existing folders for naming
	var folder_count = 0
	for track in current_project.tracks:
		if track.type == Track.TrackType.FOLDER:
			folder_count += 1
	
	var folder_name = "Folder %d" % (folder_count + 1)

	# Use Project's create_folder_track method
	# This creates both folder track and bus channel with proper linking
	var result = current_project.create_folder_track(folder_name, true)
	var new_folder = result["track"] as Track
	var new_channel = result["channel"] as Channel

	# Set visual properties
	new_folder.color = new_channel.color
	new_folder.height = 60

	print("[Arranger] Added folder '%s' (ID %d) with bus channel (ID %d)" % [folder_name, new_folder.id, new_channel.id])

# ============================================================================
# PROJECT LIFECYCLE
# ============================================================================

func _on_project_activated(project: Project) -> void:
	"""Called when a project is activated - bind to its signals."""
	# Clean up old connections if any
	if current_project:
		_unbind_from_project()
	
	current_project = project
	
	# Create shared grid_helper for timeline and ruler (Arranger owns it)
	grid_helper.ppq = project.ppq
	grid_helper.time_numerator = project.time_numerator
	grid_helper.time_denominator = project.time_denominator
	
	# Set grid_helper on timeline and ruler
	timeline.grid_helper = grid_helper
	ruler.set_grid_helper(grid_helper)  # Use setter to connect signals
	
	# Initialize target zoom values from project
	target_pixels_per_beat = grid_helper.pixels_per_beat
	if project.tracks.size() > 0:
		var total_height = 0.0
		for track in project.tracks:
			total_height += track.height
		target_track_height = total_height / project.tracks.size()
	
	# Connect to project's track signals
	current_project.track_added.connect(_on_track_added)
	current_project.track_removed.connect(_on_track_removed)
	current_project.start_position_changed.connect(_on_start_position_changed)
	
	# Initialize timeline with project
	timeline.set_project(project)
	
	# Connect to existing tracks (Timeline creates TimelineTrack UI for them, but doesn't emit signals)
	for track in project.tracks:
		_on_track_added(track)

	# Connect ruler signals and initialize with current start position
	if ruler:
		ruler.start_position_requested.connect(_on_ruler_start_position_requested)
		ruler.set_start_position(project.start_position_ticks)

	print("[Arranger] Project activated: ", project.project_name)


func _on_project_closed() -> void:
	"""Disconnect from current project signals."""
	if current_project:
		_unbind_from_project()
	current_project = null


func _unbind_from_project() -> void:
	"""Disconnect from current project signals."""
	if current_project:
		if current_project.track_added.is_connected(_on_track_added):
			current_project.track_added.disconnect(_on_track_added)
		if current_project.track_removed.is_connected(_on_track_removed):
			current_project.track_removed.disconnect(_on_track_removed)
		if current_project.start_position_changed.is_connected(_on_start_position_changed):
			current_project.start_position_changed.disconnect(_on_start_position_changed)

	if ruler and ruler.start_position_requested.is_connected(_on_ruler_start_position_requested):
		ruler.start_position_requested.disconnect(_on_ruler_start_position_requested)
	
	# Clear timeline
	timeline.set_project(null)

	_timeline_tracks.clear()

	current_project = null


# ============================================================================
# HELPERS
# ============================================================================

func _on_track_added(track: Track) -> void:
	"""Connect to new TimelineTrack when added."""
	# Wait a frame for the TimelineTrack to be created
	await get_tree().process_frame

	# Find the TimelineTrack UI for this track
	var timeline_track = _get_timeline_track_for_track(track)
	if not timeline_track:
		return

	if not timeline_track.empty_area_clicked.is_connected(_on_timeline_track_clicked):
		timeline_track.empty_area_clicked.connect(_on_timeline_track_clicked)
	
	# Store reference for later lookup
	_timeline_tracks[timeline_track] = track


func _on_track_removed(track: Track) -> void:
	"""Clean up selection tracking when a track is removed."""
	# Remove from timeline_tracks mapping
	for timeline_track in _timeline_tracks.keys():
		if _timeline_tracks[timeline_track] == track:
			_timeline_tracks.erase(timeline_track)
			break
	
	print("[Arranger] Cleaned up tracking for removed track: ", track.name)


func _on_timeline_track_clicked(ticks: int, _pixels: float) -> void:
	"""Handle timeline track click to set playhead position."""
	if Sonara and Sonara.editor:
		Sonara.editor.set_playhead(ticks)
		print("[Arranger] Set playhead to tick %d" % ticks)


func _get_track_index_at_position(global_position: Vector2) -> int:
	"""Find which track is under the global mouse position."""
	if not timeline:
		return -1

	# Convert global to local position in timeline
	var local_pos = timeline.get_local_mouse_position()

	# Find which TimelineTrack is under this position
	for i in range(timeline.timeline_tracks.size()):
		var timeline_track = timeline.timeline_tracks[i]
		if not timeline_track:
			continue

		var track_rect = timeline_track.get_rect()
		if track_rect.has_point(local_pos):
			return i

	return -1


func _find_track_by_id(track_id: int) -> Track:
	"""Find a track by its ID."""
	for track in current_project.tracks:
		if track.id == track_id:
			return track
	return null


func _get_timeline_track_for_track(track: Track) -> TimelineTrack:
	"""Get the TimelineTrack UI element for a given Track data object."""
	if not current_project or not timeline:
		return null

	var track_index = current_project.tracks.find(track)
	if track_index >= 0 and track_index < timeline.timeline_tracks.size():
		return timeline.timeline_tracks[track_index]

	return null


func _on_h_split_dragged(offset: int) -> void:
	"""Handle HSplit dragging to sync TracklistHeader width with tracks panel."""
	if _syncing_split:
		return

	_syncing_split = true
	# Sync TracklistHeader width to match the split offset, accounting for the draggable area
	tracklist_header.custom_minimum_size.x = offset + 7
	_syncing_split = false


func _on_start_position_changed(ticks: int) -> void:
	"""Update ruler when start position changes."""
	if ruler:
		ruler.set_start_position(ticks)


func _on_ruler_start_position_requested(ticks: int) -> void:
	"""Handle ruler click to set start position and seek to it."""
	if current_project:
		current_project.set_start_position(ticks)
		# Also seek playhead to the new start position
		if Sonara and Sonara.editor:
			Sonara.editor.set_playhead(ticks)
		print("[Arranger] Set start position to tick %d and seeked playhead" % ticks)


func _on_timeline_clips_selected(clips: Array[ClipInstance], multi_track: bool) -> void:
	"""Re-emit Timeline's clip selection signal."""
	clips_selected.emit(clips, multi_track)
