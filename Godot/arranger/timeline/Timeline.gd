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
var grid_helper: GridHelper:
	get:
		return _grid_helper
	set(value):
		_grid_helper = value
		if clip_selection_manager:
			clip_selection_manager.grid_helper = value
var _grid_helper: GridHelper = null

var clip_selection_manager: ClipSelectionManager = ClipSelectionManager.new()

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

func _ready():
	clip_selection_manager.set_context(self, grid_helper)
	clip_selection_manager.selection_changed.connect(_on_clip_selection_changed)
	clip_selection_manager.box_selection_changed.connect(func(_rect): queue_redraw())


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
		if project.track_removed.is_connected(_on_track_removed):
			project.track_removed.disconnect(_on_track_removed)
	
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

	# Find correct position based on order property
	var insert_position = _find_insert_position(track.order)

	# Add to container at correct position
	add_child(timeline_track)
	move_child(timeline_track, insert_position)

	# Set timeline reference for grid drawing (MUST be set before bind_to_track)
	timeline_track.timeline = self

	# Bind to track data
	timeline_track.bind_to_track(track, index)

	# Connect to track signals for reordering
	track.order_changed.connect(_on_track_order_changed)

	# Store reference
	if index >= timeline_tracks.size():
		timeline_tracks.resize(index + 1)
	timeline_tracks[index] = timeline_track

	# Update timeline width in case this track has clips
	_update_timeline_width()

	print("[Timeline] Timeline track added for: ", track.name, " at index ", index, " with order ", track.order)


func _on_track_removed(track: Track) -> void:
	"""Remove the TimelineTrack UI element for the removed track."""
	var timeline_track = _find_timeline_track(track)
	if not timeline_track:
		push_warning("[Timeline] Timeline track not found for removed track: %s" % track.name)
		return
	
	# Disconnect from track signals
	if track.order_changed.is_connected(_on_track_order_changed):
		track.order_changed.disconnect(_on_track_order_changed)
	
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


func _on_track_order_changed(_new_order: int) -> void:
	"""Handle track order changes to update visual order."""
	if not project:
		return
	
	print("[Timeline] Track order changed, updating visual order")
	_update_visual_order()


func _update_visual_order() -> void:
	"""Update UI to match hierarchical track order."""
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
	
	# Also clear any remaining children
	for child in get_children():
		child.queue_free()

	if clip_selection_manager:
		clip_selection_manager.clear_selection()
	
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
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var local_pos = get_local_mouse_position()
		if event.pressed:
			grab_focus()
			var additive = event.ctrl_pressed or event.meta_pressed or Input.is_action_pressed("ui_select")
			if additive and clip_selection_manager:
				clip_selection_manager.start_box_selection(local_pos)
				accept_event()
				return

			if clip_selection_manager:
				clip_selection_manager.clear_selection()

			var click_ticks = pixels_to_ticks(local_pos.x)
			var snapped_ticks = grid_helper.snap_ticks(click_ticks) if grid_helper else click_ticks
			Sonara.editor.set_playhead(snapped_ticks)
			accept_event()
		else:
			if clip_selection_manager and clip_selection_manager.is_box_selecting:
				var instances = _get_clip_instances_in_rect(clip_selection_manager.box_rect)
				clip_selection_manager.end_box_selection(instances)
				accept_event()
	elif event is InputEventMouseMotion:
		if clip_selection_manager and clip_selection_manager.is_box_selecting:
			clip_selection_manager.update_box_selection(get_local_mouse_position())
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
	queue_redraw()


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


func notify_clip_instance_removed(instance: ClipInstance) -> void:
	if clip_selection_manager:
		clip_selection_manager.remove_instance(instance)


func get_selected_clip_instances() -> Array[ClipInstance]:
	if clip_selection_manager:
		return clip_selection_manager.get_selected_instances()
	return []


func _get_clip_instances_in_rect(rect: Rect2) -> Array[ClipInstance]:
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
	if delta_ticks == _drag_current_tick_delta:
		return
	_drag_current_tick_delta = delta_ticks
	var tracks_to_refresh: Array[TimelineTrack] = []
	for inst in _drag_initial_positions.keys():
		var base_start: int = _drag_initial_positions[inst]
		var new_start = max(0, base_start + delta_ticks)
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


func _find_track_index_at_global_position(global_position: Vector2) -> int:
	var local_pos = make_canvas_position_local(global_position)
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
	print("[Timeline] Copied %d clips to clipboard" % clip_clipboard.clip_instances.size())


func cut_selection_to_clipboard() -> void:
	if not clip_selection_manager or not clip_selection_manager.has_selection():
		clip_clipboard = null
		print("[Timeline] Cut skipped - no clips selected")
		return
	clip_clipboard = clip_selection_manager.selection.clone()
	var selected = clip_selection_manager.get_selected_instances()
	for inst in selected:
		if inst and inst.track:
			inst.track.remove_clip_instance(inst)
	clip_selection_manager.clear_selection()
	print("[Timeline] Cut %d clips to clipboard" % selected.size())


func paste_clipboard() -> void:
	var playhead_ticks := Sonara.editor.playhead_ticks if Sonara and Sonara.editor else 0
	var new_instances = paste_clipboard_at(playhead_ticks)
	if new_instances.is_empty():
		print("[Timeline] Paste skipped - clipboard empty")
	else:
		print("[Timeline] Pasted %d clips at playhead %d" % [new_instances.size(), playhead_ticks])


func paste_clipboard_at(target_tick: int, selection_source: ClipSelection = null, update_selection: bool = true) -> Array[ClipInstance]:
	if not Sonara.editor or not Sonara.editor.project:
		push_warning("[Timeline] Cannot paste clips - no active project")
		return []

	var source := selection_source
	if source == null:
		source = clip_clipboard

	if source == null or source.is_empty():
		return []

	var delta_ticks := target_tick - source.start_tick
	var new_instances: Array[ClipInstance] = []

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
		var new_instance = target_track.create_clip_instance(clip_ref, new_start, original_inst.duration_ticks)
		new_instance.set_clip_offset(original_inst.clip_offset)
		new_instance.set_loop_enabled(original_inst.loop_enabled)
		new_instance.loop_start_ticks = original_inst.loop_start_ticks
		new_instance.loop_length_ticks = original_inst.loop_length_ticks
		new_instance.transpose = original_inst.transpose
		new_instance.gain_offset = original_inst.gain_offset
		new_instance.muted = original_inst.muted
		new_instance.fade_in_ticks = original_inst.fade_in_ticks
		new_instance.fade_out_ticks = original_inst.fade_out_ticks
		new_instance.color_override = original_inst.color_override
		new_instances.append(new_instance)

	if new_instances.is_empty():
		return []

	if update_selection and clip_selection_manager:
		clip_selection_manager.select_instances(new_instances)
		clip_selection_manager.refresh_after_modification()

	_refresh_tracks_for_instances(new_instances)
	return new_instances


func duplicate_selection() -> void:
	if not clip_selection_manager or not clip_selection_manager.has_selection():
		return

	var selection_clone = clip_selection_manager.selection.clone()
	if selection_clone.is_empty():
		return

	var previous_clipboard = clip_clipboard
	clip_clipboard = selection_clone
	var new_instances = paste_clipboard_at(selection_clone.end_tick, selection_clone, true)
	clip_clipboard = previous_clipboard if previous_clipboard else selection_clone

	if not new_instances.is_empty():
		print("[Timeline] Duplicated %d clips starting at %d" % [new_instances.size(), selection_clone.end_tick])


func move_selection_by_ticks(delta_ticks: int) -> void:
	if delta_ticks == 0:
		return
	var selected = clip_selection_manager.get_selected_instances()
	if selected.is_empty():
		return
	var tracks_to_refresh: Array[TimelineTrack] = []
	for inst in selected:
		if not inst:
			continue
		var new_start = max(0, inst.start_ticks + delta_ticks)
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


func _on_clip_drag_moved(clip_ui: TimelineClip, global_position: Vector2) -> void:
	if not clip_ui or not clip_ui.clip_instance:
		return
	_ensure_drag_initialized(clip_ui.clip_instance, true)
	var anchor_index = _drag_initial_track_indices.get(clip_ui.clip_instance, _get_track_index_for_instance(clip_ui.clip_instance))
	var target_index = _find_track_index_at_global_position(global_position)
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


func _draw() -> void:
	if not clip_selection_manager:
		return

	var theme_fill = Color(1, 1, 1, 0.1)
	var theme_stroke = Color(1, 1, 1, 0.4)

	if clip_selection_manager.is_box_selecting and clip_selection_manager.box_rect.size.length() > 0:
		var rect := clip_selection_manager.box_rect.abs()
		draw_rect(rect, theme_fill, true)
		draw_rect(rect, theme_stroke, false, 2.0)

	var bounds = clip_selection_manager.get_selection_bounds()
	if bounds.x != bounds.y:
		var start_x = ticks_to_pixels(bounds.x)
		var end_x = ticks_to_pixels(bounds.y)
		draw_line(Vector2(start_x, 0), Vector2(start_x, size.y), theme_stroke, 2.0)
		draw_line(Vector2(end_x, 0), Vector2(end_x, size.y), theme_stroke, 2.0)


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
