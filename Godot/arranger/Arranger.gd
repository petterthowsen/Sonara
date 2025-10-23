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
#  Tracks can have independently varying heights, these must be synced to the height of visual track grid in thhe timeline (and midi/audio clips)
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

# Current project reference
var current_project: Project = null

# Shared grid helper for timeline and ruler
var grid_helper: GridHelper = GridHelper.new()  # Default grid helper instance

# Selection tracking (track_id -> Array[ClipInstance])
var _track_selections: Dictionary = {}  # Tracks which clips are selected in each track
var _timeline_tracks: Dictionary = {}   # Maps TimelineTrack to its corresponding Track

# Cross-track drag state
var _dragging_source_track: Track = null
var _dragging_origin_track_index: int = -1
var _dragging_origin_mouse_pos: Vector2 = Vector2.ZERO

# Signal for multi-track selection changes
signal clips_selected(clips: Array[ClipInstance], multi_track: bool)

func _ready():
	# Set Timeline reference for drag event forwarding
	timeline.arranger = self

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

	# Connect to Editor signals for project lifecycle, playhead, and musical properties
	Sonara.editor.project_activated.connect(_on_project_activated)
	Sonara.editor.playhead_moved.connect(_on_playhead_moved)
	Sonara.editor.tempo_changed.connect(_on_tempo_changed)
	Sonara.editor.time_signature_changed.connect(_on_time_signature_changed)
	
	# Initial ruler and playhead update
	_update_ruler()
	_update_playhead_position()


func _process(_delta: float) -> void:
	"""Update ruler and playhead every frame to sync with timeline."""
	_update_ruler()
	_update_playhead_position()

func _gui_input(event: InputEvent) -> void:
	"""Handle middle-mouse button panning from timeline area."""
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
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
		h_scroll.scroll_horizontal = int(pan_start_h_scroll - delta.x)
		# Update grid_helper to keep it in sync
		grid_helper.scroll_position = h_scroll.scroll_horizontal
		v_scroll.scroll_vertical = int(pan_start_v_scroll - delta.y)
		accept_event()

# ============================================================================
# INPUT HANDLING
# ============================================================================

func _on_scroll_container_input(event: InputEvent, scroll_container: ScrollContainer) -> void:
	"""Intercept scroll events on scroll containers."""
	if event is InputEventMouseButton and event.pressed:
		var scroll_amount = 0.0
		var is_scroll_up = false
		
		# Detect scroll wheel
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			scroll_amount = -30.0
			is_scroll_up = true
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			scroll_amount = 30.0
			is_scroll_up = false
		
		if scroll_amount != 0.0:
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
					var zoom_ticks = grid_helper.pixels_to_ticks(int(zoom_pixel_x))

					# Check if scroll position is close to origin (within 1 beat worth of pixels)
					var one_beat_pixels = grid_helper.pixels_per_beat
					var near_origin = h_scroll.scroll_horizontal < one_beat_pixels

					# Apply zoom
					var zoom_factor = 1.1 if is_scroll_up else 0.9
					var new_zoom = grid_helper.pixels_per_beat * zoom_factor
					timeline.set_zoom(new_zoom)

					# Adjust scroll position
					if near_origin:
						# Lock to origin - keep scroll at 0
						h_scroll.scroll_horizontal = 0
					else:
						# Normal cursor-relative zoom
						var new_zoom_pixel_x = grid_helper.ticks_to_pixels(zoom_ticks)
						var new_scroll = new_zoom_pixel_x - zoom_point_x
						h_scroll.scroll_horizontal = int(max(0.0, new_scroll))

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
					h_scroll.scroll_horizontal += int(scroll_amount)
					scroll_container.accept_event()
			# Normal Scroll = Vertical scroll
			else:
				if v_scroll:
					v_scroll.scroll_vertical += int(scroll_amount)
					scroll_container.accept_event()

func _on_h_scroll_changed(_value: float) -> void:
	"""Update ruler and playhead when horizontal scroll changes."""
	_update_ruler()
	_update_playhead_position()

func _on_playhead_moved(_ticks: int) -> void:
	"""Update playhead visual position when playhead moves."""
	_update_playhead_position()

func _on_tempo_changed(_tempo: float) -> void:
	"""Update grid helper when tempo changes (currently tempo doesn't affect grid calculations)."""
	# Note: Tempo doesn't directly affect grid spacing, only playback speed
	# Grid is based on PPQ and time signature, not tempo
	pass

func _on_time_signature_changed(numerator: int, denominator: int) -> void:
	"""Update grid helper when time signature changes."""
	if not grid_helper:
		return
	
	grid_helper.time_numerator = numerator
	grid_helper.time_denominator = denominator
	print("[Arranger] Time signature changed to %d/%d" % [numerator, denominator])

func _unhandled_input(event: InputEvent) -> void:
	"""Handle middle mouse button panning (only if not handled by child controls)."""
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				is_panning = true
				pan_start_pos = get_global_mouse_position()
				if h_scroll:
					pan_start_h_scroll = h_scroll.scroll_horizontal
				if v_scroll:
					pan_start_v_scroll = v_scroll.scroll_vertical
				get_viewport().set_input_as_handled()
			else:
				is_panning = false
				get_viewport().set_input_as_handled()
	
	elif event is InputEventMouseMotion:
		if is_panning:
			var current_pos = get_global_mouse_position()
			var delta = current_pos - pan_start_pos
			if h_scroll:
				h_scroll.scroll_horizontal = int(pan_start_h_scroll - delta.x)
				# Also update grid_helper to keep it in sync
				if grid_helper:
					grid_helper.scroll_position = h_scroll.scroll_horizontal
			if v_scroll:
				v_scroll.scroll_vertical = int(pan_start_v_scroll - delta.y)
			get_viewport().set_input_as_handled()

func _zoom_tracks_vertically(zoom_in: bool) -> void:
	"""Zoom tracks vertically by adjusting their heights."""
	if not current_project or current_project.tracks.size() == 0:
		return

	# Calculate average track height
	var total_height = 0.0
	for track in current_project.tracks:
		total_height += track.height
	var avg_height = total_height / current_project.tracks.size()

	# Calculate new height
	var zoom_factor = 1.1 if zoom_in else 0.9
	var new_height = avg_height * zoom_factor

	# Get minimum height from TrackItem (check first available TrackItem)
	var min_height = 30.0  # Fallback minimum
	if track_list:
		for child in track_list.get_children():
			if child is TrackItem:
				min_height = max(min_height, child.get_minimum_size().y)
				break

	# Clamp to reasonable bounds
	new_height = clamp(new_height, min_height, 200.0)

	# Update all tracks to the new height
	for track in current_project.tracks:
		track.height = int(new_height)

	# Force UI update by triggering track item refresh
	if track_list:
		for child in track_list.get_children():
			if child is TrackItem and child.track:
				child.custom_minimum_size.y = child.track.height


func _update_ruler() -> void:
	"""Update ruler with current scroll position."""
	if not grid_helper:
		return
	
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
	
	# Initialize timeline with project
	timeline.set_project(project)

	# Connect to project's track signals
	current_project.track_added.connect(_on_track_added)
	current_project.start_position_changed.connect(_on_start_position_changed)

	# Connect ruler signals and initialize with current start position
	if ruler:
		ruler.start_position_requested.connect(_on_ruler_start_position_requested)
		ruler.set_start_position(project.start_position_ticks)

	print("[Arranger] Project activated: ", project.project_name)


func _unbind_from_project() -> void:
	"""Disconnect from current project signals."""
	if current_project:
		if current_project.track_added.is_connected(_on_track_added):
			current_project.track_added.disconnect(_on_track_added)
		if current_project.start_position_changed.is_connected(_on_start_position_changed):
			current_project.start_position_changed.disconnect(_on_start_position_changed)

	if ruler and ruler.start_position_requested.is_connected(_on_ruler_start_position_requested):
		ruler.start_position_requested.disconnect(_on_ruler_start_position_requested)
	
	# Clear timeline
	timeline.set_project(null)

	# Clear selection state
	_track_selections.clear()
	_timeline_tracks.clear()


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
	# Connect to selection changes
	if not timeline_track.selection_changed.is_connected(_on_timeline_track_selection_changed):
		timeline_track.selection_changed.connect(_on_timeline_track_selection_changed.bind(track))
	# Connect to deselect request (for single-track selection)
	timeline_track.deselect_other_tracks_requested.connect(_on_deselect_other_tracks_requested.bind(track))
	# Store reference for later lookup
	_timeline_tracks[timeline_track] = track

func _on_timeline_track_clicked(ticks: int, _pixels: float) -> void:
	"""Handle timeline track click to set playhead position."""
	if Sonara and Sonara.editor:
		Sonara.editor.set_playhead(ticks)
		print("[Arranger] Set playhead to tick %d" % ticks)

func _on_deselect_other_tracks_requested(requesting_track: Track) -> void:
	"""Handle request to deselect all other tracks (single-track selection mode)."""
	# Deselect all tracks except the requesting one
	for timeline_track in _timeline_tracks.keys():
		var track = _timeline_tracks[timeline_track]
		if track != requesting_track:
			# Deselect this track
			timeline_track._deselect_all()
			timeline_track._emit_selection_changed()


func _on_timeline_track_selection_changed(selected_clips: Array[ClipInstance], track: Track) -> void:
	"""Handle selection changes in a track."""
	if selected_clips.is_empty():
		# Track has no selection
		_track_selections.erase(track.id)
	else:
		# Track has selection
		_track_selections[track.id] = selected_clips

	# Emit signal with multi-track awareness
	var is_multi_track = _track_selections.size() > 1
	var all_selected : Array[ClipInstance] = []
	for clips_array in _track_selections.values():
		all_selected.append_array(clips_array)

	clips_selected.emit(all_selected, is_multi_track)


func _on_clip_drag_started(source_track: Track, selected_clip_uis: Array, selected_instances: Array[ClipInstance]) -> void:
	"""Handle cross-track drag start - store origin state."""
	_dragging_source_track = source_track
	# Use visual track list for correct hierarchical ordering
	var visual_tracks = current_project.get_visual_track_list()
	_dragging_origin_track_index = visual_tracks.find(source_track)
	_dragging_origin_mouse_pos = get_global_mouse_position()
	print("[Arranger] Drag started from track %s (index %d)" % [source_track.name, _dragging_origin_track_index])


func _on_clip_drag_moved(global_position: Vector2) -> void:
	"""Handle cross-track drag movement - move clips as mouse moves between tracks."""
	if not _dragging_source_track or _dragging_origin_track_index < 0:
		return

	# Calculate target track index based on mouse Y position
	var target_track_index = _get_track_index_at_position(global_position)
	if target_track_index < 0:
		return

	# Calculate delta from CURRENT position (not original), so we only move by 1 track at a time
	var track_delta = target_track_index - _dragging_origin_track_index

	if track_delta == 0:
		# Still in same track, no movement needed
		return

	# Move all selected clips by track_delta
	_move_selected_clips_by_track_delta(track_delta)

	# Update origin to current position so next move is incremental
	_dragging_origin_track_index = target_track_index


func _on_clip_drag_ended(global_position: Vector2) -> void:
	"""Handle cross-track drag end - finalize position."""
	_dragging_source_track = null
	_dragging_origin_track_index = -1
	_dragging_origin_mouse_pos = Vector2.ZERO


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


func _move_selected_clips_by_track_delta(track_delta: int) -> void:
	"""Move all selected clips by track_delta, maintaining relative positions."""
	if track_delta == 0:
		return

	# Use visual track list for correct hierarchical ordering
	var visual_tracks = current_project.get_visual_track_list()

	# Collect all clips that will be moved and their source tracks
	var clips_to_move: Array = []  # Array of {clip: ClipInstance, from_track: Track, to_track: Track}

	for track_id in _track_selections.keys():
		# Find the source track by ID
		var source_track = _find_track_by_id(track_id)
		if not source_track:
			continue

		# Get the target track index using visual ordering
		var source_index = visual_tracks.find(source_track)
		var target_index = source_index + track_delta

		# Check bounds
		if target_index < 0 or target_index >= visual_tracks.size():
			print("[Arranger] Skip track %d: target index %d out of bounds" % [source_index, target_index])
			continue

		var target_track = visual_tracks[target_index]
		var selected_clips = _track_selections[track_id]

		for clip in selected_clips:
			clips_to_move.append({
				"clip": clip,
				"from_track": source_track,
				"to_track": target_track
			})

	# Move all clips
	for move_info in clips_to_move:
		var clip = move_info["clip"] as ClipInstance
		var from_track = move_info["from_track"] as Track
		var to_track = move_info["to_track"] as Track

		from_track.remove_clip_instance(clip)
		to_track.add_clip_instance(clip)

	print("[Arranger] Moved %d clips by %d tracks" % [clips_to_move.size(), track_delta])

	# Update selection state to reflect new track locations
	_update_selection_after_move()


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


func _update_selection_after_move() -> void:
	"""Update selection dictionary after clips are moved to new tracks."""
	var new_selections: Dictionary = {}

	for track_id in _track_selections.keys():
		var old_track = _find_track_by_id(track_id)
		if not old_track:
			continue

		# The clips should now be on different tracks, but we need to find them
		# For now, just clear old selections and let UI refresh
		# This is imperfect but works for basic functionality

	# Clear and let selection be recalculated through normal UI flow
	_track_selections.clear()


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
