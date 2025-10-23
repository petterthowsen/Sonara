# Timeline.gd
# Container for TimelineTrack UI elements
# Managed by Arranger - does not listen to Editor signals directly

class_name Timeline extends VBoxContainer

# Timeline track items indexed by track index
var timeline_tracks: Array[TimelineTrack] = []

# Current project reference (set by Arranger)
var project: Project = null

# Minimum timeline length (in bars) when empty
const MIN_TIMELINE_BARS: int = 32  # Show at least 32 bars

# Grid helper for consistent snapping (set by Arranger)
var grid_helper: GridHelper

# Reference to Arranger for forwarding drag events
var arranger: Node = null

func _ready():
	mouse_filter = Control.MOUSE_FILTER_PASS


# ============================================================================
# PROJECT MANAGEMENT (called by Arranger)
# ============================================================================
func set_project(new_project: Project) -> void:
	"""Set the project and initialize timeline. Called by Arranger."""
	# Clean up old connections if any
	if project:
		_unbind_from_project()
	
	project = new_project
	
	if project:
		# Connect to project's track signals
		project.track_added.connect(_on_track_added)
		
		# Sync UI with existing tracks
		for i in range(project.tracks.size()):
			_on_track_added(project.tracks[i])
		
		# Update grid and timeline
		_update_timeline_width()
		
		print("[Timeline] Project set: ", project.project_name)
	else:
		print("[Timeline] Project cleared")

func _unbind_from_project() -> void:
	"""Disconnect from current project signals and clear UI."""
	if project:
		if project.track_added.is_connected(_on_track_added):
			project.track_added.disconnect(_on_track_added)
	
	_clear_all_tracks()
	project = null


func _on_track_added(track: Track) -> void:
	"""Create a TimelineTrack UI element for the new track."""
	# Find track index in the project
	var index = project.tracks.find(track)
	if index < 0:
		push_error("[Timeline] Track not found in project")
		return

	# Instantiate TimelineTrack
	var timeline_track = TimelineTrack.new()
	if timeline_track == null:
		push_error("[Timeline] Failed to instantiate TimelineTrack")
		return

	# Find correct position based on order property
	var insert_position = _find_insert_position(track.order)

	# Add to container at correct position
	add_child(timeline_track)
	move_child(timeline_track, insert_position)

	# Bind to track data
	timeline_track.bind_to_track(track, index)

	# Set timeline reference for grid drawing
	timeline_track.timeline = self

	# Connect drag signals to forward to Arranger
	if arranger:
		if not timeline_track.clip_drag_started.is_connected(arranger._on_clip_drag_started):
			timeline_track.clip_drag_started.connect(arranger._on_clip_drag_started)
		if not timeline_track.clip_drag_moved.is_connected(arranger._on_clip_drag_moved):
			timeline_track.clip_drag_moved.connect(arranger._on_clip_drag_moved)
		if not timeline_track.clip_drag_ended.is_connected(arranger._on_clip_drag_ended):
			timeline_track.clip_drag_ended.connect(arranger._on_clip_drag_ended)

	# Store reference
	if index >= timeline_tracks.size():
		timeline_tracks.resize(index + 1)
	timeline_tracks[index] = timeline_track

	# Update timeline width in case this track has clips
	_update_timeline_width()

	print("[Timeline] Timeline track added for: ", track.name, " at index ", index, " with order ", track.order)

# ============================================================================
# INTERNAL HELPERS
# ============================================================================

func _clear_all_tracks() -> void:
	"""Remove all timeline tracks."""
	for timeline_track in timeline_tracks:
		if timeline_track:
			timeline_track.queue_free()
	timeline_tracks.clear()
	
	# Also clear any remaining children
	for child in get_children():
		child.queue_free()
	
	print("[Timeline] All timeline tracks cleared")


func _find_insert_position(order: int) -> int:
	"""Find the correct position to insert a timeline track based on its order value."""
	var insert_pos = 0
	for child in get_children():
		if child is TimelineTrack:
			var child_track = child as TimelineTrack
			if child_track.track and child_track.track.order <= order:
				insert_pos += 1
			else:
				break
	return insert_pos


func _gui_input(event: InputEvent) -> void:
	""" handle left-click empty area to set playhead position """
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var local_pos = get_local_mouse_position()
		var click_ticks = pixels_to_ticks(local_pos.x)
		var snapped_ticks = grid_helper.snap_ticks(click_ticks)
		Sonara.editor.set_playhead(snapped_ticks)
		accept_event()


# ============================================================================
# ZOOM AND SCROLL
# ============================================================================
func set_zoom(new_pixels_per_beat: float) -> void:
	"""Set the zoom level (pixels per beat)."""
	grid_helper.pixels_per_beat = new_pixels_per_beat
	_update_timeline_width()
	_redraw_all_tracks()

func set_scroll_offset(offset: float) -> void:
	"""Set the horizontal scroll offset."""
	grid_helper.scroll_position = offset
	_redraw_all_tracks()

func _redraw_all_tracks() -> void:
	"""Request redraw for all timeline tracks and update clip positions."""
	for timeline_track in timeline_tracks:
			timeline_track.queue_redraw()
			# Update clip positions when zoom changes
			if timeline_track.has_method("_update_clip_positions"):
				timeline_track._update_clip_positions()


func get_snap_interval() -> int:
	"""Get the current snap interval in ticks."""
	return grid_helper.get_snap_interval()


func _update_timeline_width() -> void:
	"""Update the minimum width of the timeline based on content length."""
	if not project:
		return
	
	# Calculate the end position of the last clip across all tracks
	var last_clip_end_ticks = 0
	for track : Track in project.tracks:
		for clip in track.clip_instances:
			var clip_end = clip.start_ticks + clip.duration_ticks
			if clip_end > last_clip_end_ticks:
				last_clip_end_ticks = clip_end
	
	# Calculate minimum width based on content or default minimum
	var ppq = project.ppq
	var ticks_per_bar = ppq * project.time_numerator
	var min_ticks = MIN_TIMELINE_BARS * ticks_per_bar
	
	# Use whichever is larger: content length or minimum
	var timeline_ticks = max(last_clip_end_ticks, min_ticks)
	
	# Add some padding (2 bars)
	timeline_ticks += ticks_per_bar * 2
	
	# Convert to pixels
	var timeline_width = ticks_to_pixels(timeline_ticks)
	
	# Set minimum width on this container
	custom_minimum_size.x = timeline_width
	
	print("[Timeline] Updated width to ", timeline_width, " pixels (", timeline_ticks, " ticks)")

# ============================================================================
# COORDINATE CONVERSION
# ============================================================================
func ticks_to_pixels(ticks: int) -> float:
	"""Convert ticks to pixel position."""
	return grid_helper.ticks_to_pixels(ticks)

func pixels_to_ticks(pixels: float) -> int:
	"""Convert pixel position to ticks."""
	return grid_helper.pixels_to_ticks(pixels)
