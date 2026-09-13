# Timeline.gd
# Container for TimelineTrack UI elements
# Managed by Arranger - does not listen to Editor signals directly

class_name Timeline extends VBoxContainer

# Timeline track items indexed by track index
var timeline_tracks: Array[TimelineTrack] = []

# Current project reference (set by Arranger)
var project: Project = null
var _is_rebuilding: bool = false

# Minimum timeline length (in bars) when empty
const MIN_TIMELINE_BARS: int = 32  # Show at least 32 bars

# Grid helper for consistent snapping (set by Arranger)
var grid_helper: GridHelper:
	get:
		return _grid_helper
	set(value):
		# Disconnect from old grid_helper if any
		if _grid_helper and _grid_helper.changed.is_connected(_on_grid_helper_changed):
			_grid_helper.changed.disconnect(_on_grid_helper_changed)

		_grid_helper = value

		# Connect to new grid_helper for scroll position updates
		if _grid_helper:
			_grid_helper.changed.connect(_on_grid_helper_changed)

		if clip_selection_manager:
			clip_selection_manager.grid_helper = value
var _grid_helper: GridHelper = null

var clip_selection_manager: ClipSelectionManager = ClipSelectionManager.new()
@onready var clip_ctx_menu = $ClipContextMenu

# Signal emitted when clip selection changes
signal clips_selected(clips: Array[ClipInstance], multi_track: bool)

var _drag_active: bool = false
var _drag_cross_track: bool = false
var _drag_anchor_instance: ClipInstance = null
var _drag_initial_positions: Dictionary = {}  # ClipInstance -> int
var _drag_initial_track_indices: Dictionary = {}  # ClipInstance -> int
var _drag_selected_instances: Array[ClipInstance] = []
var _drag_current_tick_delta: int = 0
var _drag_pending_track_delta: int = 0
var clip_clipboard: ClipSelection = null

@export var selection_boundary_color: Color = Color(0.4, 0.8, 1.0, 0.6)

func _ready():
	clip_selection_manager.set_context(self, grid_helper)
	clip_selection_manager.selection_changed.connect(_on_clip_selection_changed)
	clip_selection_manager.box_selection_changed.connect(func(_rect): queue_redraw())

	# Clip Context Menu
	if not clip_ctx_menu.delete_requested.is_connected(_on_clip_delete_requested):
		clip_ctx_menu.delete_requested.connect(_on_clip_delete_requested)

	if not clip_ctx_menu.make_unique_requested.is_connected(_on_clip_make_unique_requested):
		clip_ctx_menu.make_unique_requested.connect(_on_clip_make_unique_requested)


func _on_grid_helper_changed() -> void:
	"""Update timeline width when grid_helper properties change (scroll, zoom, etc)."""
	_update_timeline_width()


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
		project.track_removed.connect(_on_track_removed)
		project.tracks_layout_changed.connect(_on_tracks_layout_changed)
		
		# Sync UI with existing tracks, then apply folder hierarchy order
		_is_rebuilding = true
		for i in range(project.tracks.size()):
			_on_track_added(project.tracks[i])
		_is_rebuilding = false
		_update_visual_order()
		
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
		if project.track_removed.is_connected(_on_track_removed):
			project.track_removed.disconnect(_on_track_removed)
		if project.tracks_layout_changed.is_connected(_on_tracks_layout_changed):
			project.tracks_layout_changed.disconnect(_on_tracks_layout_changed)
	
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
	var timeline_track := TimelineTrack.new()

	# Append; visual order is applied from the folder hierarchy after add/rebuild.
	add_child(timeline_track)

	# Set timeline reference for grid drawing (MUST be set before bind_to_track)
	timeline_track.timeline = self

	# Bind to track data
	timeline_track.bind_to_track(track, index)

	# Connect to track signals for reordering / folder reparent
	track.order_changed.connect(_on_track_layout_changed)
	track.parent_changed.connect(_on_track_layout_changed)

	# Store reference
	if index >= timeline_tracks.size():
		timeline_tracks.resize(index + 1)
	timeline_tracks[index] = timeline_track

	# Update timeline width in case this track has clips
	_update_timeline_width()

	if not _is_rebuilding:
		_update_visual_order()

	print("[Timeline] Timeline track added for: ", track.name, " at index ", index, " with order ", track.order)


func _on_track_removed(track: Track) -> void:
	"""Remove the TimelineTrack UI element for the removed track."""
	var timeline_track = _find_timeline_track(track)
	if not timeline_track:
		push_warning("[Timeline] Timeline track not found for removed track: %s" % track.name)
		return
	
	# Disconnect from track signals
	if track.order_changed.is_connected(_on_track_layout_changed):
		track.order_changed.disconnect(_on_track_layout_changed)
	if track.parent_changed.is_connected(_on_track_layout_changed):
		track.parent_changed.disconnect(_on_track_layout_changed)
	
	# Remove from timeline_tracks array
	var index = timeline_tracks.find(timeline_track)
	if index >= 0:
		timeline_tracks.remove_at(index)

	# Remove selection references for clips on this track
	if clip_selection_manager:
		for clip_ui in timeline_track.clip_instances:
			if clip_ui:
				clip_selection_manager.unregister_clip_ui(clip_ui)
				if clip_ui.clip_instance:
					clip_selection_manager.remove_instance(clip_ui.clip_instance)
	
	# Remove from scene tree and free
	timeline_track.queue_free()
	
	# Update timeline width in case this affects layout
	_update_timeline_width()
	
	print("[Timeline] Timeline track removed for: ", track.name)


## Rebuild UI order when a track's sibling order or folder parent changes.
func _on_track_layout_changed(_unused: int) -> void:
	if not project or project.is_track_layout_batching():
		return
	_update_visual_order()


## Rebuild after a batched reorder so clips stay aligned with TrackList during live drag.
func _on_tracks_layout_changed() -> void:
	if not project:
		return
	_update_visual_order()


## Update UI to match hierarchical track order.
func _update_visual_order() -> void:
	if not project:
		return
	
	# Get flat visual list from hierarchy
	var visual_tracks = project.get_visual_track_list()
	
	# Reorder children to match visual order
	for i in range(visual_tracks.size()):
		var track = visual_tracks[i]
		var timeline_track = _find_timeline_track(track)
		if timeline_track:
			move_child(timeline_track, i)
	
	# Rebuild timeline_tracks array to match visual order
	timeline_tracks.clear()
	for i in range(get_child_count()):
		var child = get_child(i)
		if child is TimelineTrack:
			timeline_tracks.append(child as TimelineTrack)
	
	print("[Timeline] Updated visual order (%d tracks)" % visual_tracks.size())


func _find_timeline_track(track: Track) -> TimelineTrack:
	"""Find the TimelineTrack UI element for a given track."""
	for child in get_children():
		if child is TimelineTrack:
			var item = child as TimelineTrack
			if item.track == track:
				return item
	return null


# ============================================================================
# INTERNAL HELPERS
# ============================================================================

func _clear_all_tracks() -> void:
	"""Remove all timeline tracks."""
	for timeline_track in timeline_tracks:
		if timeline_track:
			if clip_selection_manager:
				for clip_ui in timeline_track.clip_instances:
					if clip_ui:
						clip_selection_manager.unregister_clip_ui(clip_ui)
						if clip_ui.clip_instance:
							clip_selection_manager.remove_instance(clip_ui.clip_instance)
			timeline_track.queue_free()
	timeline_tracks.clear()
	_drag_active = false
	_drag_cross_track = false
	_drag_anchor_instance = null
	_drag_initial_positions.clear()
	_drag_initial_track_indices.clear()
	_drag_selected_instances.clear()
	_drag_current_tick_delta = 0
	_drag_pending_track_delta = 0

	if clip_selection_manager:
		clip_selection_manager.clear_selection()
	
	print("[Timeline] All timeline tracks cleared")


## Left-click empty space: Ctrl/Cmd starts a time-range gesture; otherwise set the playhead.
## Right-click empty space clears clip selection and hides the time-range lines.
func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton:
		return

	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if is_local_position_on_clip(get_local_mouse_position()):
			return
		if clip_selection_manager:
			clip_selection_manager.clear_selection()
		accept_event()
		return

	if event.button_index != MOUSE_BUTTON_LEFT or not event.pressed:
		return

	var local_pos = get_local_mouse_position()
	var additive = event.ctrl_pressed or event.meta_pressed or Input.is_action_pressed("ui_select")
	if additive and clip_selection_manager:
		clip_selection_manager.begin_additive_gesture(local_pos)
		accept_event()
		return

	if clip_selection_manager:
		clip_selection_manager.clear_selection()

	var click_ticks = pixels_to_ticks(local_pos.x)
	var snapped_ticks = grid_helper.snap_ticks(click_ticks) if grid_helper else click_ticks
	Sonara.editor.set_playhead(snapped_ticks)
	accept_event()


## Keep Ctrl/Cmd click-or-drag tracking the mouse even when it travels over clips.
func _input(event: InputEvent) -> void:
	if not clip_selection_manager:
		return
	if not clip_selection_manager.is_box_selecting and not clip_selection_manager.is_additive_pending:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		clip_selection_manager.finish_additive_gesture(get_local_mouse_position())
		accept_event()
		return

	if not is_visible_in_tree():
		return

	if event is InputEventMouseMotion:
		clip_selection_manager.update_additive_gesture(get_local_mouse_position())
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
		if timeline_track:
			timeline_track._update_clip_positions()
			timeline_track.queue_redraw()
	queue_redraw()


func refresh_layout() -> void:
	"""Force a full layout refresh: width, clip sizes, positions, and redraw.
	Use after the Arranger becomes visible to correct zero-height track sizing when hidden."""
	_update_timeline_width()
	for timeline_track in timeline_tracks:
		if not timeline_track:
			continue
		# Ensure clip sizes match current track height (fixes zero-height when previously hidden)
		var height := int(timeline_track.size.y)
		# If size is zero (hidden state), fall back to track height when available
		if height <= 0 and timeline_track.track:
			height = int(timeline_track.track.height)
		timeline_track._update_clip_sizes(height)
		# Update positions after sizes
		timeline_track._update_clip_positions()
		# Redraw track
		timeline_track.queue_redraw()
	# Redraw timeline container
	queue_redraw()


func get_snap_interval() -> int:
	"""Get the current snap interval in ticks."""
	return grid_helper.get_snap_interval()


func _update_timeline_width() -> void:
	"""Update the minimum width of the timeline based on content length and scroll position."""
	if not project or not grid_helper:
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

	# Calculate the visible viewport extent in ticks to enable infinite scroll
	# We need to ensure timeline extends beyond current scroll position + viewport
	var scroll_ticks = grid_helper.pixels_to_ticks(grid_helper.scroll_position)
	var parent_scroll = get_parent()
	var viewport_width = 1000.0  # fallback
	if parent_scroll is ScrollContainer:
		viewport_width = parent_scroll.size.x
	var viewport_ticks = grid_helper.pixels_to_ticks(viewport_width)
	var scroll_end_ticks = scroll_ticks + viewport_ticks

	# Add buffer beyond scroll (8 bars) to allow smooth scrolling ahead
	var scroll_buffer_ticks = ticks_per_bar * 8
	var scroll_extent_ticks = scroll_end_ticks + scroll_buffer_ticks

	# Use whichever is larger: content length, minimum, or scroll extent
	var timeline_ticks = max(last_clip_end_ticks, min_ticks, scroll_extent_ticks)

	# Add some padding (2 bars)
	timeline_ticks += ticks_per_bar * 2

	# Convert to pixels
	var timeline_width = ticks_to_pixels(timeline_ticks)

	# Set minimum width on this container
	custom_minimum_size.x = timeline_width

# ============================================================================
# COORDINATE CONVERSION
# ============================================================================
func ticks_to_pixels(ticks: int) -> float:
	"""Convert ticks to pixel position."""
	return grid_helper.ticks_to_pixels(ticks)

func pixels_to_ticks(pixels: float) -> int:
	"""Convert pixel position to ticks."""
	if not grid_helper:
		return int(pixels)
	return grid_helper.pixels_to_ticks(pixels)


func get_move_step_ticks() -> int:
	var interval = get_snap_interval()
	if interval <= 0:
		if project and project.ppq > 0:
			return max(1, project.ppq / 4)
		return 1
	return interval


func register_clip_ui(clip_ui: TimelineClip) -> void:
	if clip_selection_manager:
		clip_selection_manager.register_clip_ui(clip_ui)
	if not clip_ui:
		return
	if not clip_ui.clip_move_requested.is_connected(_on_clip_move_requested):
		clip_ui.clip_move_requested.connect(_on_clip_move_requested)

	if not clip_ui.drag_started.is_connected(_on_clip_drag_started):
		clip_ui.drag_started.connect(_on_clip_drag_started)

	if not clip_ui.drag_moved.is_connected(_on_clip_drag_moved):
		clip_ui.drag_moved.connect(_on_clip_drag_moved)

	if not clip_ui.drag_ended.is_connected(_on_clip_drag_ended):
		clip_ui.drag_ended.connect(_on_clip_drag_ended)

	if not clip_ui.context_menu_requested.is_connected(_on_clip_context_menu_requested):
		clip_ui.context_menu_requested.connect(_on_clip_context_menu_requested)


func unregister_clip_ui(clip_ui: TimelineClip) -> void:
	if clip_selection_manager:
		clip_selection_manager.unregister_clip_ui(clip_ui)
	
	if not clip_ui:
		return
	
	if clip_ui.clip_move_requested.is_connected(_on_clip_move_requested):
		clip_ui.clip_move_requested.disconnect(_on_clip_move_requested)
	
	if clip_ui.drag_started.is_connected(_on_clip_drag_started):
		clip_ui.drag_started.disconnect(_on_clip_drag_started)
	
	if clip_ui.drag_moved.is_connected(_on_clip_drag_moved):
		clip_ui.drag_moved.disconnect(_on_clip_drag_moved)
	
	if clip_ui.drag_ended.is_connected(_on_clip_drag_ended):
		clip_ui.drag_ended.disconnect(_on_clip_drag_ended)

	if clip_ui.context_menu_requested.is_connected(_on_clip_context_menu_requested):
		clip_ui.context_menu_requested.disconnect(_on_clip_context_menu_requested)


func notify_clip_instance_removed(instance: ClipInstance) -> void:
	if clip_selection_manager:
		clip_selection_manager.remove_instance(instance)


func get_selected_clip_instances() -> Array[ClipInstance]:
	if clip_selection_manager:
		return clip_selection_manager.get_selected_instances()
	return []


## Return clip instances whose on-timeline rect intersects `rect`.
func get_clip_instances_in_rect(rect: Rect2) -> Array[ClipInstance]:
	var hits: Array[ClipInstance] = []
	if rect.size.length() == 0:
		return hits

	var check_rect := rect.abs()
	for track in timeline_tracks:
		if not track:
			continue
		var track_top_left = track.position
		var track_rect = Rect2(track_top_left, track.size)
		if not check_rect.intersects(track_rect):
			continue

		for clip_ui in track.clip_instances:
			if not clip_ui:
				continue
			var clip_rect = Rect2(track_top_left + clip_ui.position, clip_ui.size)
			if check_rect.intersects(clip_rect):
				var inst = clip_ui.clip_instance
				if inst and not hits.has(inst):
					hits.append(inst)
	return hits


func _clamp_instances_tick_delta(instances: Array[ClipInstance], requested_tick_delta: int, track_delta: int = 0, use_initial_positions: bool = false) -> int:
	"""Clamp the tick delta to the maximum legal movement without causing collisions.
	Returns the clamped delta (may be less than requested, or even 0 if no movement is possible).
	If use_initial_positions is true, uses _drag_initial_positions instead of current positions."""
	if instances.is_empty():
		return requested_tick_delta
	
	var max_delta = requested_tick_delta
	var direction = 1 if requested_tick_delta > 0 else -1 if requested_tick_delta < 0 else 0
	
	if direction == 0:
		return 0
	
	# For each moving clip, find the maximum it can move before overlapping with another clip
	for inst in instances:
		if not inst or not inst.track:
			continue
		
		# Determine which track to check (current or target after vertical move)
		var check_track: Track = inst.track
		if track_delta != 0:
			var current_index = _get_track_index_for_instance(inst)
			var target_index = current_index + track_delta
			if target_index >= 0 and target_index < timeline_tracks.size():
				var target_track_node: TimelineTrack = timeline_tracks[target_index]
				if target_track_node and target_track_node.track:
					check_track = target_track_node.track
		
		# Use initial position if available, otherwise use current position
		var inst_start: int
		if use_initial_positions and _drag_initial_positions.has(inst):
			inst_start = _drag_initial_positions[inst]
		else:
			inst_start = inst.start_ticks
		
		var inst_duration = inst.duration_ticks
		
		var inst_end = inst_start + inst_duration
		
		# Check each clip on the track to see if we would collide
		for other_instance in check_track.clip_instances:
			# Skip if it's the same instance or if it's one of the moving instances
			if other_instance == inst or instances.has(other_instance):
				continue
			
			var other_start = other_instance.start_ticks
			var other_end = other_instance.start_ticks + other_instance.duration_ticks
			
			# Calculate the proposed position with the requested delta
			var proposed_start = inst_start + requested_tick_delta
			var proposed_end = proposed_start + inst_duration
			
			# Check if the proposed position would cause an overlap
			if proposed_start < other_end and other_start < proposed_end:
				# Would overlap - calculate the maximum delta that wouldn't overlap
				if direction > 0:
					# Moving right: stop just before this clip
					var available_space = other_start - inst_end
					max_delta = min(max_delta, available_space)
				else:
					# Moving left: stop just after this clip
					var available_space = inst_start - other_end
					max_delta = max(max_delta, -available_space)
	
	# Ensure we don't go below zero
	for inst in instances:
		if not inst:
			continue
		var base_start: int
		if use_initial_positions and _drag_initial_positions.has(inst):
			base_start = _drag_initial_positions[inst]
		else:
			base_start = inst.start_ticks
		
		var new_start = base_start + max_delta
		if new_start < 0:
			max_delta = -base_start
	
	return max_delta


func _ensure_drag_initialized(instance: ClipInstance, cross_track: bool) -> void:
	if not instance:
		return
	if not _drag_active:
		_drag_active = true
		_drag_cross_track = cross_track
		_drag_anchor_instance = instance
		_drag_initial_positions.clear()
		_drag_initial_track_indices.clear()
		_drag_selected_instances = clip_selection_manager.get_selected_instances()
		if _drag_selected_instances.is_empty():
			_drag_selected_instances = [instance]
		for inst in _drag_selected_instances:
			if not inst:
				continue
			_drag_initial_positions[inst] = inst.start_ticks
			_drag_initial_track_indices[inst] = _get_track_index_for_instance(inst)
		_drag_current_tick_delta = 0
		_drag_pending_track_delta = 0
	elif cross_track:
		_drag_cross_track = true


func _apply_horizontal_drag(delta_ticks: int) -> void:
	if not _drag_active:
		return
	
	# Clamp the delta to avoid collisions (use initial positions for stable calculation)
	var clamped_delta = _clamp_instances_tick_delta(_drag_selected_instances, delta_ticks, 0, true)
	
	if clamped_delta == _drag_current_tick_delta:
		return
	
	_drag_current_tick_delta = clamped_delta
	var tracks_to_refresh: Array[TimelineTrack] = []
	for inst in _drag_initial_positions.keys():
		var base_start: int = _drag_initial_positions[inst]
		var new_start = max(0, base_start + clamped_delta)
		if inst.start_ticks == new_start:
			continue
		inst.set_position(new_start)
		var track_ui = _get_timeline_track_for_instance(inst)
		if track_ui and not tracks_to_refresh.has(track_ui):
			tracks_to_refresh.append(track_ui)
	for track_ui in tracks_to_refresh:
		if track_ui:
			track_ui._update_clip_positions()
			track_ui.queue_redraw()
	queue_redraw()


func _apply_vertical_drag(delta_tracks: int) -> void:
	if not _drag_active or delta_tracks == 0:
		return
	var allowed_delta = _clamp_track_delta(delta_tracks)
	if allowed_delta == 0:
		return

	# Clamp horizontal position to avoid collisions on target tracks (use initial positions)
	var clamped_tick_delta = _clamp_instances_tick_delta(_drag_selected_instances, _drag_current_tick_delta, allowed_delta, true)
	
	# If horizontal position needs adjustment, apply it
	if clamped_tick_delta != _drag_current_tick_delta:
		_drag_current_tick_delta = clamped_tick_delta
		# Update positions with clamped delta
		for inst in _drag_initial_positions.keys():
			var base_start: int = _drag_initial_positions[inst]
			var new_start = max(0, base_start + clamped_tick_delta)
			inst.set_position(new_start)

	var target_instances: Array[ClipInstance] = []
	target_instances.assign(_drag_selected_instances)

	for inst in target_instances:
		if not inst:
			continue
		var origin_index = _drag_initial_track_indices.get(inst, _get_track_index_for_instance(inst))
		if origin_index == -1:
			continue
		var target_index = origin_index + allowed_delta
		if target_index < 0 or target_index >= timeline_tracks.size():
			continue
		var target_track_node: TimelineTrack = timeline_tracks[target_index]
		if not target_track_node or not target_track_node.track:
			continue
		if target_track_node.track.type == Track.TrackType.FOLDER:
			continue
		var current_track: Track = inst.track
		if current_track == target_track_node.track:
			continue
		current_track.remove_clip_instance(inst)
		target_track_node.track.add_clip_instance(inst)

	_drag_pending_track_delta = allowed_delta
	if not target_instances.is_empty():
		clip_selection_manager.select_instances(target_instances)
	queue_redraw()


func _finish_drag() -> void:
	if not _drag_active:
		return

	# Record undo for move / cross-track move before clearing drag state
	var cmds: Array[Command] = []
	for inst in _drag_selected_instances:
		if not inst:
			continue
		var old_start: int = _drag_initial_positions.get(inst, inst.start_ticks)
		var old_track_idx: int = _drag_initial_track_indices.get(inst, -1)
		var old_track: Track = null
		if old_track_idx >= 0 and old_track_idx < timeline_tracks.size():
			old_track = timeline_tracks[old_track_idx].track
		var new_track: Track = inst.track
		var new_start: int = inst.start_ticks
		if old_track != null and new_track != null and old_track != new_track:
			cmds.append(ClipInstanceMoveTrackCommand.new(inst, old_track, new_track, old_start, new_start))
		elif old_start != new_start:
			cmds.append(ClipInstanceTransformCommand.new(
				"Move Clip", inst,
				old_start, inst.duration_ticks, inst.clip_offset,
				new_start, inst.duration_ticks, inst.clip_offset
			))
	if cmds.size() == 1:
		HistoryUtil.record(cmds[0])
	elif cmds.size() > 1:
		HistoryUtil.record(MacroCommand.new("Move Clips", cmds))

	_drag_active = false
	_drag_cross_track = false
	_drag_anchor_instance = null
	_drag_initial_positions.clear()
	_drag_initial_track_indices.clear()
	_drag_selected_instances.clear()
	_drag_current_tick_delta = 0
	_drag_pending_track_delta = 0
	clip_selection_manager.refresh_after_modification()
	queue_redraw()


func _clamp_track_delta(requested_delta: int) -> int:
	return _compute_allowed_track_delta(_drag_selected_instances, _drag_initial_track_indices, requested_delta)


func _compute_allowed_track_delta(instances: Array[ClipInstance], initial_indices: Dictionary, requested_delta: int) -> int:
	if requested_delta == 0:
		return 0
	var direction = 1 if requested_delta > 0 else -1
	var allowed_delta = requested_delta
	while allowed_delta != 0:
		var valid = true
		for inst in instances:
			if not inst:
				continue
			var origin_index = initial_indices.get(inst, _get_track_index_for_instance(inst))
			if origin_index == -1:
				continue
			var target_index = origin_index + allowed_delta
			if target_index < 0 or target_index >= timeline_tracks.size():
				valid = false
				break
			var target_track_node: TimelineTrack = timeline_tracks[target_index]
			if not target_track_node or not target_track_node.track:
				valid = false
				break
			if target_track_node.track.type == Track.TrackType.FOLDER:
				valid = false
				break
		if valid:
			return allowed_delta
		allowed_delta -= direction
	return 0


func _get_track_index_for_instance(instance: ClipInstance) -> int:
	for i in range(timeline_tracks.size()):
		var track_node: TimelineTrack = timeline_tracks[i]
		for clip_ui in track_node.clip_instances:
			if clip_ui and clip_ui.clip_instance == instance:
				return i
	return -1


func _get_timeline_track_for_instance(instance: ClipInstance) -> TimelineTrack:
	var index = _get_track_index_for_instance(instance)
	if index >= 0 and index < timeline_tracks.size():
		return timeline_tracks[index]
	return null


func _find_track_index_at_global_position(mouse_pos_global: Vector2) -> int:
	var local_pos = make_canvas_position_local(mouse_pos_global)
	var y = local_pos.y
	for i in range(timeline_tracks.size()):
		var track_node: TimelineTrack = timeline_tracks[i]
		var track_top = track_node.position.y
		var track_bottom = track_top + track_node.size.y
		if y >= track_top and y <= track_bottom:
			return i
	return -1


func copy_selection_to_clipboard() -> void:
	if not clip_selection_manager or not clip_selection_manager.has_selection():
		clip_clipboard = null
		print("[Timeline] Copy skipped - no clips selected")
		return
	clip_clipboard = clip_selection_manager.selection.clone()
	_apply_time_range_to_clipboard(clip_clipboard)
	print("[Timeline] Copied %d clips to clipboard" % clip_clipboard.clip_instances.size())


func cut_selection_to_clipboard() -> void:
	if not clip_selection_manager or not clip_selection_manager.has_selection():
		clip_clipboard = null
		print("[Timeline] Cut skipped - no clips selected")
		return
	clip_clipboard = clip_selection_manager.selection.clone()
	_apply_time_range_to_clipboard(clip_clipboard)
	var selected = clip_selection_manager.get_selected_instances()
	var cmds: Array[Command] = []
	for inst in selected:
		if inst and inst.track:
			cmds.append(ClipInstanceDeleteCommand.new(inst.track, inst))
	if cmds.size() == 1:
		HistoryUtil.execute(cmds[0])
	elif cmds.size() > 1:
		HistoryUtil.execute(MacroCommand.new("Cut Clips", cmds))
	clip_selection_manager.clear_selection()
	print("[Timeline] Cut %d clips to clipboard" % selected.size())


## Paste clipboard clips at the selection start (or playhead). Refuses if they would overlap.
func paste_clipboard() -> void:
	var playhead_ticks := Sonara.editor.playhead_ticks if Sonara and Sonara.editor else 0
	var target_tick := clip_selection_manager.get_paste_tick(playhead_ticks) if clip_selection_manager else playhead_ticks
	if clip_clipboard == null or clip_clipboard.is_empty():
		print("[Timeline] Paste skipped - clipboard empty")
		return
	if _clipboard_placement_blocked(clip_clipboard, target_tick):
		print("[Timeline] Paste skipped - no adequate space")
		return
	var new_instances = paste_clipboard_at(target_tick)
	if new_instances.is_empty():
		print("[Timeline] Paste skipped - clipboard empty")
	else:
		print("[Timeline] Pasted %d clips at tick %d" % [new_instances.size(), target_tick])


## Insert `source` (or the clipboard) at `target_tick`. Returns [] when blocked or empty.
func paste_clipboard_at(target_tick: int, selection_source: ClipSelection = null, update_selection: bool = true, action_name: String = "Paste") -> Array[ClipInstance]:
	if not Sonara.editor or not Sonara.editor.project:
		push_warning("[Timeline] Cannot paste clips - no active project")
		return []

	var source := selection_source
	if source == null:
		source = clip_clipboard

	if source == null or source.is_empty():
		return []

	if _clipboard_placement_blocked(source, target_tick):
		return []

	var delta_ticks := target_tick - source.start_tick
	var new_instances: Array[ClipInstance] = []
	var cmds: Array[Command] = []
	for original_inst in source.get_sorted_by_start():
		if not original_inst:
			continue
		var target_track: Track = original_inst.track
		if not target_track or target_track.type == Track.TrackType.FOLDER:
			continue
		var clip_ref: Clip = original_inst.clip
		if not clip_ref:
			continue

		var new_start = max(0, original_inst.start_ticks + delta_ticks)
		var new_instance := ClipInstance.new("", clip_ref.id)
		new_instance.clip = clip_ref
		new_instance.start_ticks = new_start
		new_instance.duration_ticks = original_inst.duration_ticks
		new_instance.copy_overrides_from(original_inst)
		new_instances.append(new_instance)

		var cmd := ClipInstanceCreateCommand.new(
			target_track, clip_ref, new_start, original_inst.duration_ticks,
			null, false, new_instance
		)
		cmd.name = "%s Clip" % action_name
		cmds.append(cmd)

	if new_instances.is_empty():
		return []

	if cmds.size() == 1:
		HistoryUtil.execute(cmds[0])
	else:
		HistoryUtil.execute(MacroCommand.new("%s Clips" % action_name, cmds))

	if update_selection and clip_selection_manager:
		clip_selection_manager.select_instances(new_instances)
		clip_selection_manager.refresh_after_modification()

	_refresh_tracks_for_instances(new_instances)
	return new_instances


## Duplicate selected clips at the selection end. Refuses if they would overlap.
func duplicate_selection() -> void:
	if not clip_selection_manager or not clip_selection_manager.has_selection():
		return

	var selection_clone = clip_selection_manager.selection.clone()
	if selection_clone.is_empty():
		return
	_apply_time_range_to_clipboard(selection_clone)

	var previous_clipboard = clip_clipboard
	clip_clipboard = selection_clone
	var target_tick := clip_selection_manager.get_duplicate_tick(selection_clone.end_tick)
	if _clipboard_placement_blocked(selection_clone, target_tick):
		clip_clipboard = previous_clipboard if previous_clipboard else selection_clone
		print("[Timeline] Duplicate skipped - no adequate space")
		return
	var new_instances = paste_clipboard_at(target_tick, selection_clone, true, "Duplicate")
	clip_clipboard = previous_clipboard if previous_clipboard else selection_clone

	if not new_instances.is_empty():
		print("[Timeline] Duplicated %d clips starting at %d" % [new_instances.size(), target_tick])


## True when placing `source` at `target_tick` would overlap an existing clip.
func _clipboard_placement_blocked(source: ClipSelection, target_tick: int) -> bool:
	if source == null or source.is_empty():
		return false
	var delta_ticks := target_tick - source.start_tick
	for original_inst in source.get_sorted_by_start():
		if not original_inst or not original_inst.clip:
			continue
		var target_track: Track = original_inst.track
		if not target_track or target_track.type == Track.TrackType.FOLDER:
			continue
		var new_start := maxi(0, original_inst.start_ticks + delta_ticks)
		if target_track.has_clip_overlap(new_start, original_inst.duration_ticks):
			return true
	return false


func move_selection_by_ticks(delta_ticks: int) -> void:
	if delta_ticks == 0:
		return
	var selected = clip_selection_manager.get_selected_instances()
	if selected.is_empty():
		return
	
	# Clamp the delta to avoid collisions
	var clamped_delta = _clamp_instances_tick_delta(selected, delta_ticks)
	if clamped_delta == 0:
		return
	
	var tracks_to_refresh: Array[TimelineTrack] = []
	for inst in selected:
		if not inst:
			continue
		var new_start = max(0, inst.start_ticks + clamped_delta)
		if new_start == inst.start_ticks:
			continue
		inst.set_position(new_start)
		var track_ui = _get_timeline_track_for_instance(inst)
		if track_ui and not tracks_to_refresh.has(track_ui):
			tracks_to_refresh.append(track_ui)
	for track_ui in tracks_to_refresh:
		if track_ui:
			track_ui._update_clip_positions()
			track_ui.queue_redraw()
	clip_selection_manager.refresh_after_modification()
	queue_redraw()


func move_selection_by_tracks(delta_tracks: int) -> void:
	if delta_tracks == 0:
		return
	var selected = clip_selection_manager.get_selected_instances()
	if selected.is_empty():
		return
	var initial_indices: Dictionary = {}
	for inst in selected:
		if inst:
			initial_indices[inst] = _get_track_index_for_instance(inst)
	var allowed_delta = _compute_allowed_track_delta(selected, initial_indices, delta_tracks)
	if allowed_delta == 0:
		return
	
	# Clamp horizontal positions to avoid collisions on target tracks
	var clamped_tick_delta = _clamp_instances_tick_delta(selected, 0, allowed_delta)
	
	# If we need to adjust horizontal positions (shouldn't happen with delta=0, but for safety)
	if clamped_tick_delta != 0:
		for inst in selected:
			if not inst:
				continue
			var new_start = max(0, inst.start_ticks + clamped_tick_delta)
			inst.set_position(new_start)
	
	for inst in selected:
		if not inst:
			continue
		var origin_index: int = initial_indices.get(inst, -1)
		if origin_index == -1:
			continue
		var target_index = origin_index + allowed_delta
		if target_index < 0 or target_index >= timeline_tracks.size():
			continue
		var target_track_node: TimelineTrack = timeline_tracks[target_index]
		if not target_track_node or not target_track_node.track:
			continue
		if inst.track:
			inst.track.remove_clip_instance(inst)
		target_track_node.track.add_clip_instance(inst)
	clip_selection_manager.select_instances(selected)
	clip_selection_manager.refresh_after_modification()
	_refresh_tracks_for_instances(selected)
	queue_redraw()
	print("[Timeline] Moved selection by %d track(s)" % allowed_delta)


## Stamp the visible time-range onto a clipboard so paste/duplicate keep empty lead-in.
func _apply_time_range_to_clipboard(clipboard: ClipSelection) -> void:
	if not clipboard or not clip_selection_manager or not clip_selection_manager.range_visible:
		return
	clipboard.start_tick = clip_selection_manager.range_start_tick
	if clip_selection_manager.range_has_end:
		clipboard.end_tick = clip_selection_manager.range_end_tick


func _refresh_tracks_for_instances(instances: Array[ClipInstance]) -> void:
	var tracks_to_refresh: Array[TimelineTrack] = []
	for inst in instances:
		if not inst:
			continue
		var track_ui = _get_timeline_track_for_instance(inst)
		if track_ui and not tracks_to_refresh.has(track_ui):
			tracks_to_refresh.append(track_ui)
	for track_ui in tracks_to_refresh:
		if track_ui:
			track_ui._update_clip_positions()
			track_ui.queue_redraw()


func _on_clip_move_requested(clip_ui: TimelineClip, new_start_ticks: int) -> void:
	if not clip_ui or not clip_ui.clip_instance:
		return
	_ensure_drag_initialized(clip_ui.clip_instance, false)
	var original_start: int = _drag_initial_positions.get(clip_ui.clip_instance, clip_ui.clip_instance.start_ticks)
	var delta = new_start_ticks - original_start
	_apply_horizontal_drag(delta)


func _on_clip_drag_started(clip_ui: TimelineClip, _instance: ClipInstance) -> void:
	if not clip_ui or not clip_ui.clip_instance:
		return
	_ensure_drag_initialized(clip_ui.clip_instance, true)


func _on_clip_drag_moved(clip_ui: TimelineClip, mouse_pos_global: Vector2) -> void:
	if not clip_ui or not clip_ui.clip_instance:
		return
	_ensure_drag_initialized(clip_ui.clip_instance, true)
	var anchor_index = _drag_initial_track_indices.get(clip_ui.clip_instance, _get_track_index_for_instance(clip_ui.clip_instance))
	var target_index = _find_track_index_at_global_position(mouse_pos_global)
	if anchor_index == -1 or target_index == -1:
		return
	_drag_pending_track_delta = target_index - anchor_index


func _on_clip_drag_ended(clip_ui: TimelineClip, _global_position: Vector2) -> void:
	if not clip_ui or not clip_ui.clip_instance:
		_finish_drag()
		return
	if _drag_cross_track and _drag_pending_track_delta != 0:
		_apply_vertical_drag(_drag_pending_track_delta)
	_finish_drag()



## True when `local_pos` (Timeline space) hits a clip UI.
func is_local_position_on_clip(local_pos: Vector2) -> bool:
	for track in timeline_tracks:
		if not track:
			continue
		var pos_in_track := local_pos - track.position
		for clip_ui in track.clip_instances:
			if clip_ui and clip_ui.get_rect().has_point(pos_in_track):
				return true
	return false


## Bind the clip menu to the clicked instance (or current selection) and popup at the cursor.
func _on_clip_context_menu_requested(clip_ui: TimelineClip, mouse_pos_global: Vector2) -> void:
	if not clip_ui or not clip_ui.clip_instance or not is_instance_valid(clip_ctx_menu):
		return
	# Determine selection to bind: use current selection if it contains the clicked instance; otherwise just the clicked
	var selection := get_selected_clip_instances()
	if selection.is_empty() or not selection.has(clip_ui.clip_instance):
		selection = [clip_ui.clip_instance]
	clip_ctx_menu.bind_to_instances(selection)
	# Nudge so the cursor sits inside the panel; a corner popup closes on mouse-up.
	var c_pos = mouse_pos_global - Vector2(8, 8)
	var c_size = clip_ctx_menu.get_contents_minimum_size()
	clip_ctx_menu.popup(Rect2(c_pos, c_size))


func _on_clip_delete_requested(instances: Array[ClipInstance]) -> void:
	if not instances or instances.is_empty():
		return
	var cmds: Array[Command] = []
	for inst in instances:
		if inst and inst.track:
			cmds.append(ClipInstanceDeleteCommand.new(inst.track, inst))
	if cmds.is_empty():
		return
	if cmds.size() == 1:
		HistoryUtil.execute(cmds[0])
	else:
		HistoryUtil.execute(MacroCommand.new("Delete Clips", cmds))


func _on_clip_make_unique_requested(instances: Array[ClipInstance]) -> void:
	if not instances or instances.is_empty() or not Sonara or not Sonara.editor:
		return
	var proj: Project = Sonara.editor.project
	if not proj:
		return

	var cmds: Array[Command] = []
	for instance in instances:
		if not instance or not instance.clip:
			continue
		if proj.get_clip_instance_count(instance.clip.id) <= 1:
			continue
		cmds.append(MakeClipUniqueCommand.new(proj, instance))
	if cmds.is_empty():
		return
	if cmds.size() == 1:
		HistoryUtil.execute(cmds[0])
	else:
		HistoryUtil.execute(MacroCommand.new("Make Clips Unique", cmds))



func _draw() -> void:
	if not clip_selection_manager:
		return

	var theme_fill = Color(1, 1, 1, 0.1)
	var theme_stroke = Color(1, 1, 1, 0.4)

	if clip_selection_manager.is_box_selecting and clip_selection_manager.box_rect.size.length() > 0:
		var rect := clip_selection_manager.box_rect.abs()
		draw_rect(rect, theme_fill, true)
		draw_rect(rect, theme_stroke, false, 2.0)


func _on_clip_selection_changed(instances: Array[ClipInstance]) -> void:
	# Emit Timeline's own signal with selection data and multi-track flag
	clips_selected.emit(instances, _selection_has_multiple_tracks(instances))


func _selection_has_multiple_tracks(instances: Array[ClipInstance]) -> bool:
	if instances.size() < 2:
		return false
	var track_id := -99999
	for inst in instances:
		if not inst or not inst.track:
			continue
		if track_id == -99999:
			track_id = inst.track.id
			continue
		if inst.track.id != track_id:
			return true
	return false
