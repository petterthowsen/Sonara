# Timeline.gd
# Container for TimelineTrack UI elements
# Managed by Arranger - does not listen to Editor signals directly

class_name Timeline extends VBoxContainer

var logger : Log = Log.make("Timeline")

# Timeline track items indexed by track index
var timeline_tracks: Array[TimelineTrack] = []

# Current project reference (set by Arranger)
var project: Project = null
var _is_rebuilding: bool = false

# Minimum timeline length (in bars) when empty
const MIN_TIMELINE_BARS: int = 32  # Show at least 32 bars
## The width grows in steps of this many bars. It follows the scroll position (infinite scroll),
## and every width change relayouts every lane and clip, so it must not change on every frame.
const WIDTH_STEP_BARS: int = 16
# Instanced (not TimelineTrack.new()) so the colors/border set on the scene apply
const TimelineTrackScene = preload("res://arranger/timeline/TimelineTrack.tscn")

## Grid line colors, shared by every row (track and automation lanes). Alpha is honored: lines
## are blended over the row fills.
## Bar line, drawn 2px wide.
@export var grid_color_bar: Color = Color(0.5, 0.5, 0.5, 0.66):
	set(value):
		grid_color_bar = value
		queue_redraw()

## Beat line (not a bar). Hidden when beats are closer than GridHelper.min_line_spacing.
@export var grid_color_beat: Color = Color(0.35, 0.35, 0.35, 0.47):
	set(value):
		grid_color_beat = value
		queue_redraw()

## Subdivision line between beats: the finest level at least GridHelper.min_line_spacing apart.
@export var grid_color_tick: Color = Color(0.21, 0.21, 0.21, 0.2):
	set(value):
		grid_color_tick = value
		queue_redraw()

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
		if automation_selection_manager:
			automation_selection_manager.grid_helper = value
var _grid_helper: GridHelper = null

var clip_selection_manager: ClipSelectionManager = ClipSelectionManager.new()
@onready var clip_ctx_menu = $ClipContextMenu

## Automation point selection, the counterpart of `clip_selection_manager` (REQ-020, REQ-021).
var automation_selection_manager: AutomationPointSelectionManager = AutomationPointSelectionManager.new()

## Timeline lane rows, keyed by the AutomationLane they show. They are direct children of this
## VBox so AutomationRowOrder can interleave them with the TimelineTracks.
var _lane_rows: Dictionary = {}

## Rows from the last _update_visual_order, resized on every fold animation step.
var _fold_rows: Array = []

# Signal emitted when clip selection changes
signal clips_selected(clips: Array[ClipInstance], multi_track: bool)

## Clip move drag. The Timeline tracks it in _input because a cross-track move frees the clip UI
## that was pressed.
var _drag_active: bool = false
var _drag_anchor_instance: ClipInstance = null
var _drag_origin_clip_ui: TimelineClip = null  # Holds mouse focus while alive and gets the release
var _drag_press_global: Vector2 = Vector2.ZERO
var _drag_initial_positions: Dictionary = {}  # ClipInstance -> int
var _drag_initial_track_indices: Dictionary = {}  # ClipInstance -> int
var _drag_selected_instances: Array[ClipInstance] = []
var _drag_current_tick_delta: int = 0
var _drag_current_track_delta: int = 0
var clip_clipboard: ClipSelection = null

@export var selection_boundary_color: Color = Color(0.4, 0.8, 1.0, 0.6)

func _ready():
	# remove any tracks
	for child in get_children():
		if child is TimelineTrack:
			remove_child(child)
			child.queue_free()
	
	clip_selection_manager.set_context(self, grid_helper)
	clip_selection_manager.selection_changed.connect(_on_clip_selection_changed)
	clip_selection_manager.box_selection_changed.connect(func(_rect): queue_redraw())

	# Clip Context Menu
	if not clip_ctx_menu.delete_requested.is_connected(_on_clip_delete_requested):
		clip_ctx_menu.delete_requested.connect(_on_clip_delete_requested)

	if not clip_ctx_menu.make_unique_requested.is_connected(_on_clip_make_unique_requested):
		clip_ctx_menu.make_unique_requested.connect(_on_clip_make_unique_requested)

	if not clip_ctx_menu.cut_requested.is_connected(_on_clip_cut_requested):
		clip_ctx_menu.cut_requested.connect(_on_clip_cut_requested)

	if not clip_ctx_menu.split_requested.is_connected(_on_clip_split_requested):
		clip_ctx_menu.split_requested.connect(_on_clip_split_requested)
	if not clip_ctx_menu.merge_requested.is_connected(_on_clip_merge_requested):
		clip_ctx_menu.merge_requested.connect(_on_clip_merge_requested)

	if not clip_ctx_menu.copy_requested.is_connected(_on_clip_copy_requested):
		clip_ctx_menu.copy_requested.connect(_on_clip_copy_requested)

	automation_selection_manager.grid_helper = grid_helper
	automation_selection_manager.selection_changed.connect(_on_automation_selection_changed)
	automation_selection_manager.range_changed.connect(_redraw_lane_rows)


func _on_grid_helper_changed() -> void:
	"""Update timeline width when grid_helper properties change (scroll, zoom, etc)."""
	_update_timeline_width()
	# Scroll/zoom changes shift which part of the grid is visible. The row backgrounds and the
	# automation curves only draw the visible range, so they redraw here (a pure scroll doesn't
	# resize anything, so NOTIFICATION_RESIZED won't fire). Track lanes draw nothing themselves.
	queue_redraw()
	_redraw_lane_rows()


## TimelineTracks whose clips were given an on-screen range by the last _update_clip_windows.
var _rows_on_screen: Dictionary = {}


func _process(_delta: float) -> void:
	_update_clip_windows()


## Tell every clip on an on-screen row which part of it is visible, so its notes are drawn only
## there (MidiclipRenderer.show_px_range); clips on rows that just left the screen drop theirs.
## Runs after Arranger._process (parents process first) has applied this frame's scroll and
## zoom, and before the deferred redraws those queued.
func _update_clip_windows() -> void:
	var view := _visible_content_rect() if is_visible_in_tree() else Rect2()
	var on_screen: Dictionary = {}
	if view.has_area():
		for row in timeline_tracks:
			if not is_instance_valid(row) or not row.visible:
				continue
			if row.position.y >= view.end.y or row.position.y + row.size.y <= view.position.y:
				continue
			on_screen[row] = true
			for clip_ui in row.clip_instances:
				if is_instance_valid(clip_ui) and clip_ui.clip_renderer:
					var x0: float = row.position.x + clip_ui.position.x + clip_ui.clip_renderer.position.x
					clip_ui.clip_renderer.show_px_range(view.position.x - x0, view.end.x - x0)
	for row in _rows_on_screen:
		if on_screen.has(row) or not is_instance_valid(row):
			continue
		for clip_ui in row.clip_instances:
			if is_instance_valid(clip_ui) and clip_ui.clip_renderer:
				clip_ui.clip_renderer.show_px_range(0.0, 0.0)
	_rows_on_screen = on_screen


## The part of this control that is on screen, in local coordinates: the viewport clipped by
## every ancestor that clips its contents (the horizontal and vertical ScrollContainers).
func _visible_content_rect() -> Rect2:
	var rect := get_viewport_rect()
	var node := get_parent()
	while node is CanvasItem:
		if node is Control and node.clip_contents:
			rect = rect.intersection(node.get_global_rect())
		node = node.get_parent()
	if not rect.has_area():
		return Rect2()
	return get_global_transform().affine_inverse() * rect


## Rows moved or resized (reorder, fold animation, track height, automation lanes shown or
## hidden): the row backgrounds drawn in _draw follow them.
func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN or what == NOTIFICATION_RESIZED:
		queue_redraw()


func get_viewport_width() -> float:
	"""Return the width of the enclosing ScrollContainer's viewport, if any."""
	var parent_scroll = get_parent()
	if parent_scroll is ScrollContainer:
		return parent_scroll.size.x
	return size.x


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
		
		logger.info("Project set: ", project.project_name)
	else:
		logger.info("Project cleared")

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
	var timeline_track: TimelineTrack = TimelineTrackScene.instantiate()

	# Append; visual order is applied from the folder hierarchy after add/rebuild.
	add_child(timeline_track)

	# Set timeline reference for grid drawing (MUST be set before bind_to_track)
	timeline_track.timeline = self

	# Bind to track data
	timeline_track.bind_to_track(track, index)

	# Connect to track signals for reordering / folder reparent
	track.order_changed.connect(_on_track_layout_changed)
	track.parent_changed.connect(_on_track_layout_changed)

	# Automation lane rows follow the track's lanes and its disclosure state.
	track.automation_lane_added.connect(_on_automation_lane_added.bind(track))
	track.automation_lane_removed.connect(_on_automation_lane_removed)
	track.automation_expanded_changed.connect(_on_automation_expanded_changed)
	track.folder_expanded_changed.connect(_on_folder_expanded_changed.bind(track))
	for lane in track.automation_lanes:
		_ensure_lane_row(track, lane)

	# Store reference
	if index >= timeline_tracks.size():
		timeline_tracks.resize(index + 1)
	timeline_tracks[index] = timeline_track

	# Update timeline width in case this track has clips
	_update_timeline_width()

	if not _is_rebuilding:
		_update_visual_order()

	logger.info("Timeline track added for: ", track.name, " at index ", index, " with order ", track.order)


func _on_track_removed(track: Track) -> void:
	"""Remove the TimelineTrack UI element for the removed track."""
	var timeline_track = _find_timeline_track(track)
	if not timeline_track:
		push_warning("[Timeline] Timeline track not found for removed track: %s" % track.name)
		return
	
	_disconnect_track_layout_signals(track)
	_clear_lane_rows(track)
	
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
	
	logger.info("Timeline track removed for: ", track.name)


## Undo the per-track layout connections made in _on_track_added.
func _disconnect_track_layout_signals(track: Track) -> void:
	if track == null:
		return
	if track.order_changed.is_connected(_on_track_layout_changed):
		track.order_changed.disconnect(_on_track_layout_changed)
	if track.parent_changed.is_connected(_on_track_layout_changed):
		track.parent_changed.disconnect(_on_track_layout_changed)
	for connection in track.automation_lane_added.get_connections():
		if connection["callable"].get_object() == self:
			track.automation_lane_added.disconnect(connection["callable"])
	if track.automation_lane_removed.is_connected(_on_automation_lane_removed):
		track.automation_lane_removed.disconnect(_on_automation_lane_removed)
	if track.automation_expanded_changed.is_connected(_on_automation_expanded_changed):
		track.automation_expanded_changed.disconnect(_on_automation_expanded_changed)
	for connection in track.folder_expanded_changed.get_connections():
		if connection["callable"].get_object() == self:
			track.folder_expanded_changed.disconnect(connection["callable"])


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
	
	# One ordering helper for both arranger columns, so rows can't drift out of alignment.
	var rows := AutomationRowOrder.build(project)
	_fold_rows = rows
	_sync_lane_row_visibility(rows)
	_sync_track_row_visibility(rows)
	AutomationRowOrder.apply(self, rows, _node_for_row)
	AutomationRowOrder.apply_heights(project, rows, _node_for_row)
	
	# Rebuild timeline_tracks array to match visual order
	timeline_tracks.clear()
	for i in range(get_child_count()):
		var child = get_child(i)
		# Folded-away rows are skipped so cross-track clip drags only land on shown tracks.
		if child is TimelineTrack and child.visible:
			timeline_tracks.append(child as TimelineTrack)
	
	logger.info("Updated visual order (%d rows)" % rows.size())


## Hide TimelineTracks of tracks folded away (not in `rows`); apply_heights() shows the rest.
func _sync_track_row_visibility(rows: Array) -> void:
	var shown: Dictionary = {}
	for row in rows:
		if row.get("lane") == null:
			shown[row["track"]] = true
	for child in get_children():
		if child is TimelineTrack and (child as TimelineTrack).track:
			child.visible = shown.has((child as TimelineTrack).track)


## Follow the same fold slide as TrackList (TrackFoldAnimation.start is shared and idempotent).
func _on_folder_expanded_changed(_expanded: bool, track: Track) -> void:
	if project == null:
		return
	var anim := TrackFoldAnimation.start(track)
	if anim and not anim.updated.is_connected(_on_fold_step):
		anim.updated.connect(_on_fold_step)
		anim.finished.connect(_update_visual_order)
	_update_visual_order()


## Resize rows for the current fold animation step.
func _on_fold_step() -> void:
	if project:
		AutomationRowOrder.apply_heights(project, _fold_rows, _node_for_row)


## The child Control representing `row`: a TimelineTrack for a track row, the lane's row for a
## lane row.
func _node_for_row(row: Dictionary) -> Node:
	var lane: AutomationLane = row.get("lane")
	if lane == null:
		return _find_timeline_track(row["track"])
	var lane_row = _lane_rows.get(lane)
	return lane_row if is_instance_valid(lane_row) else null


## Show only the lane rows AutomationRowOrder put in `rows`, keeping the rest alive so a
## re-checked lane comes back instantly with its points and height.
func _sync_lane_row_visibility(rows: Array) -> void:
	var shown: Dictionary = {}
	for row in rows:
		var lane: AutomationLane = row.get("lane")
		if lane != null:
			shown[lane] = true
	for lane in _lane_rows:
		var lane_row = _lane_rows[lane]
		if is_instance_valid(lane_row):
			lane_row.visible = shown.has(lane)


# ============================================================================
# AUTOMATION LANE ROWS (REQ-013)
# ============================================================================

func _ensure_lane_row(track: Track, lane: AutomationLane) -> AutomationLaneRow:
	if lane == null:
		return null
	var existing = _lane_rows.get(lane)
	if is_instance_valid(existing):
		return existing

	var lane_row := AutomationLaneRow.new()
	add_child(lane_row)
	lane_row.bind_to_lane(lane, track, self)
	lane.visibility_changed.connect(_on_lane_visibility_changed)
	_lane_rows[lane] = lane_row
	return lane_row


func _clear_lane_rows(track: Track) -> void:
	if track == null:
		return
	for lane in track.automation_lanes:
		_drop_lane_row(lane)


func _drop_lane_row(lane: AutomationLane) -> void:
	if lane == null:
		return
	if lane.visibility_changed.is_connected(_on_lane_visibility_changed):
		lane.visibility_changed.disconnect(_on_lane_visibility_changed)
	automation_selection_manager.forget_lane(lane)
	var lane_row = _lane_rows.get(lane)
	if is_instance_valid(lane_row):
		lane_row.queue_free()
	_lane_rows.erase(lane)


func _on_automation_lane_added(lane: AutomationLane, track: Track) -> void:
	_ensure_lane_row(track, lane)
	_update_visual_order()


func _on_automation_lane_removed(lane: AutomationLane) -> void:
	_drop_lane_row(lane)
	_update_visual_order()


func _on_automation_expanded_changed(_expanded: bool) -> void:
	_update_visual_order()


func _on_lane_visibility_changed(_visible: bool) -> void:
	_update_visual_order()


## Clearing the clip selection when points get selected (and vice versa) keeps exactly one of the
## two selections active, which is what routes cut/copy/paste in `_automation_is_active()`.
func _on_automation_selection_changed(_lane: AutomationLane, _point_ids: Array) -> void:
	if automation_selection_manager.has_selection() and clip_selection_manager.has_selection():
		clip_selection_manager.clear_selection()
	queue_redraw()
	_redraw_lane_rows()


## Selection and range highlights are drawn by the rows, and a change in one lane can clear
## another lane's, so every row redraws.
func _redraw_lane_rows() -> void:
	for lane_row in _lane_rows.values():
		if is_instance_valid(lane_row):
			lane_row.queue_redraw()


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
			_disconnect_track_layout_signals(timeline_track.track)
			if clip_selection_manager:
				for clip_ui in timeline_track.clip_instances:
					if clip_ui:
						clip_selection_manager.unregister_clip_ui(clip_ui)
						if clip_ui.clip_instance:
							clip_selection_manager.remove_instance(clip_ui.clip_instance)
			timeline_track.queue_free()
	timeline_tracks.clear()
	for lane in _lane_rows.keys():
		_drop_lane_row(lane)
	_lane_rows.clear()
	automation_selection_manager.clear_selection()
	_reset_drag_state()

	if clip_selection_manager:
		clip_selection_manager.clear_selection()
		clip_selection_manager.anchor_track = null
		clip_selection_manager.anchor_tick = -1
	
	logger.info("All timeline tracks cleared")


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

	automation_selection_manager.release()
	var local_pos = get_local_mouse_position()
	var additive = event.ctrl_pressed or event.meta_pressed or Input.is_action_pressed("ui_select")
	if additive and clip_selection_manager:
		clip_selection_manager.begin_additive_gesture(local_pos)
		accept_event()
		return

	var click_ticks = pixels_to_ticks(local_pos.x)
	var snapped_ticks = grid_helper.snap_ticks(click_ticks) if grid_helper else click_ticks
	if clip_selection_manager:
		clip_selection_manager.clear_selection()
		var lane_index := _find_track_index_at_global_position(get_global_mouse_position())
		var lane_track: Track = timeline_tracks[lane_index].track if lane_index >= 0 else null
		clip_selection_manager.set_anchor(lane_track, snapped_ticks)
	Sonara.editor.set_playhead(snapped_ticks)
	accept_event()


## Keep Ctrl/Cmd click-or-drag tracking the mouse even when it travels over clips.
func _input(event: InputEvent) -> void:
	if _drag_active:
		_handle_clip_drag_input(event)
		return
	if _handle_erase_input(event):
		return
	if not clip_selection_manager:
		return
	if not clip_selection_manager.is_box_selecting and not clip_selection_manager.is_additive_pending:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		clip_selection_manager.finish_additive_gesture(get_local_mouse_position())
		# Let the release reach the GUI: swallowing it leaves the pressed clip holding mouse
		# focus, so it keeps every later motion event and other clips never update their cursor.
		return

	if not is_visible_in_tree():
		return

	if event is InputEventMouseMotion:
		clip_selection_manager.update_additive_gesture(get_local_mouse_position())
		accept_event()


# ============================================================================
# RIGHT-DRAG ERASE
# ============================================================================
const ERASE_SETTING := "arranger/right_drag_erase"
const ERASE_THRESHOLD_PX := 6.0
const ERASE_SAMPLE_STEP_PX := 4.0

var _erase_pressed := false  # Right button went down over the lane area
var _erase_active := false  # Pointer passed the threshold: this gesture erases
var _erase_press_pos := Vector2.ZERO
var _erase_last_pos := Vector2.ZERO


## Right-press then drag past a pixel threshold deletes every clip the pointer crosses.
## Returns true when the event was consumed. A plain right-click still opens the clip menu.
func _handle_erase_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			_erase_active = false
			_erase_pressed = (Settings.get_value(ERASE_SETTING) and is_visible_in_tree()
					and get_global_rect().has_point(event.global_position)
							and _is_pointer_over_timeline()
				and not _is_over_automation_lane_row(event.global_position))
			_erase_press_pos = event.global_position
			_erase_last_pos = event.global_position
			return false
		var was_erasing := _erase_active
		_erase_pressed = false
		_erase_active = false
		if was_erasing:
			# Swallow the release so the clip under the pointer doesn't open its menu.
			get_viewport().set_input_as_handled()
		return was_erasing
	if not _erase_pressed or not event is InputEventMouseMotion:
		return false
	var pos: Vector2 = event.global_position
	if not _erase_active:
		if pos.distance_to(_erase_press_pos) < ERASE_THRESHOLD_PX:
			return false
		_erase_active = true
		_erase_last_pos = _erase_press_pos
	_erase_along(_erase_last_pos, pos)
	_erase_last_pos = pos
	get_viewport().set_input_as_handled()
	return true


## Delete clips under the segment `from`..`to` (global), sampled so fast strokes don't skip clips.
func _erase_along(from: Vector2, to: Vector2) -> void:
	var steps := maxi(1, ceili(from.distance_to(to) / ERASE_SAMPLE_STEP_PX))
	var to_local := get_global_transform().affine_inverse()
	var doomed: Array[ClipInstance] = []
	for i in range(1, steps + 1):
		var local: Vector2 = to_local * from.lerp(to, float(i) / steps)
		for lane in timeline_tracks:
			if not lane:
				continue
			var in_lane := local - lane.position
			for clip_ui in lane.clip_instances:
				if clip_ui and clip_ui.clip_instance and clip_ui.get_rect().has_point(in_lane) \
						and not doomed.has(clip_ui.clip_instance):
					doomed.append(clip_ui.clip_instance)
	var cmds: Array[Command] = []
	for inst in doomed:
		if inst.track:
			cmds.append(ClipInstanceDeleteCommand.new(inst.track, inst))
	if not cmds.is_empty():
		HistoryUtil.execute_many("Erase Clips", cmds)


## `_input` sees every click, including ones on UI stacked over the timeline's rect (device
## panels, popups). Only arm the erase gesture when the control actually under the pointer is
## the timeline or one of its descendants.
func _is_pointer_over_timeline() -> bool:
	var hovered := get_viewport().gui_get_hovered_control()
	return hovered != null and (hovered == self or is_ancestor_of(hovered))


## An automation lane row owns its own right-click (point context menu, or clearing the point
## selection on empty space) and is consumed in `_gui_input`. But `_input` runs first, so the
## erase gesture must exclude those rows here or a right-click on a point arms an erase drag.
## No clip lives in a lane row, so nothing is lost by never starting the gesture there.
func _is_over_automation_lane_row(global_pos: Vector2) -> bool:
	for lane_row in _lane_rows.values():
		if is_instance_valid(lane_row) and lane_row.is_visible_in_tree() \
				and lane_row.get_global_rect().has_point(global_pos):
			return true
	return false


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
	"""Update clip positions on every track and redraw the row backgrounds."""
	for timeline_track in timeline_tracks:
		if timeline_track:
			timeline_track._update_clip_positions()
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
	# Redraw the row backgrounds
	queue_redraw()


func get_snap_interval() -> int:
	"""Get the current snap interval in ticks."""
	return grid_helper.get_snap_interval()


## Ctrl+A: select every clip on `track`, or on every track when `track` is null.
func select_all_clips(track: Track = null) -> void:
	if not project or not clip_selection_manager:
		return
	if track != null:
		clip_selection_manager.select_all_on_track(track)
	else:
		clip_selection_manager.select_all_on_tracks(project.tracks)


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
	var ticks_per_bar = GridHelper.bar_ticks(ppq, project.time_numerator, project.time_denominator)
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

	# Add some padding (2 bars), then round up to a whole width step
	timeline_ticks += ticks_per_bar * 2
	var step_ticks: int = ticks_per_bar * WIDTH_STEP_BARS
	timeline_ticks = ceili(float(timeline_ticks) / step_ticks) * step_ticks

	# Convert to pixels
	var timeline_width = ticks_to_pixels(timeline_ticks)

	# Set minimum width on this container
	if custom_minimum_size.x != timeline_width:
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
	if clip_ui.clip_renderer:
		clip_ui.clip_renderer.enable_culling()
	if not clip_ui.drag_begin_requested.is_connected(_on_clip_drag_begin_requested):
		clip_ui.drag_begin_requested.connect(_on_clip_drag_begin_requested)

	if not clip_ui.context_menu_requested.is_connected(_on_clip_context_menu_requested):
		clip_ui.context_menu_requested.connect(_on_clip_context_menu_requested)

	if not clip_ui.open_in_editor_requested.is_connected(_on_clip_open_in_editor_requested):
		clip_ui.open_in_editor_requested.connect(_on_clip_open_in_editor_requested)


func unregister_clip_ui(clip_ui: TimelineClip) -> void:
	if clip_selection_manager:
		clip_selection_manager.unregister_clip_ui(clip_ui)
	
	if not clip_ui:
		return
	
	if clip_ui.drag_begin_requested.is_connected(_on_clip_drag_begin_requested):
		clip_ui.drag_begin_requested.disconnect(_on_clip_drag_begin_requested)

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
		
		# Determine which track to check (current or target after vertical move).
		# A drag moves clips live, so it measures from the track each clip started on.
		var check_track: Track = inst.track
		if track_delta != 0 or use_initial_positions:
			var base_index: int = _drag_initial_track_indices.get(inst, -1) if use_initial_positions else _get_track_index_for_instance(inst)
			var target_index = base_index + track_delta
			if base_index >= 0 and target_index >= 0 and target_index < timeline_tracks.size():
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


## Take over a clip move once the press on `clip_ui` passes the drag threshold.
func _on_clip_drag_begin_requested(clip_ui: TimelineClip, press_global: Vector2) -> void:
	if not clip_ui or not clip_ui.clip_instance:
		return
	_drag_active = true
	_drag_anchor_instance = clip_ui.clip_instance
	_drag_origin_clip_ui = clip_ui
	_drag_press_global = press_global
	_drag_initial_positions.clear()
	_drag_initial_track_indices.clear()
	_drag_selected_instances = clip_selection_manager.get_selected_instances()
	if not _drag_selected_instances.has(_drag_anchor_instance):
		_drag_selected_instances = [_drag_anchor_instance]
	for inst in _drag_selected_instances:
		if not inst:
			continue
		_drag_initial_positions[inst] = inst.start_ticks
		_drag_initial_track_indices[inst] = _get_track_index_for_instance(inst)
	_drag_current_tick_delta = 0
	_drag_current_track_delta = 0
	_update_clip_drag(get_global_mouse_position(), Input.is_key_pressed(KEY_SHIFT))


## Select a just-placed clip and start moving it while the placing press is still held, so the
## user can drag it into place; the release commits the move like any clip drag.
func begin_placement_drag(instance: ClipInstance) -> void:
	var clip_ui := clip_selection_manager.get_clip_ui(instance)
	if clip_ui == null:
		return
	clip_selection_manager.select_only(instance)
	_on_clip_drag_begin_requested(clip_ui, get_global_mouse_position())


## Mouse motion moves the clips, the release commits the move, and Shift toggles grid snap live.
func _handle_clip_drag_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_clip_drag(get_global_mouse_position(), event.shift_pressed)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		var origin := _drag_origin_clip_ui
		_finish_drag()
		# The pressed clip UI swallows its own release. If a cross-track move freed it, the
		# release would land on whatever is under the mouse, so stop it here.
		if not is_instance_valid(origin) or origin.is_queued_for_deletion():
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.keycode == KEY_SHIFT and not event.echo:
		_update_clip_drag(get_global_mouse_position(), event.pressed)


## Move the dragged clips to follow the mouse, onto the hovered track too. `free_move` skips snap.
func _update_clip_drag(mouse_global: Vector2, free_move: bool) -> void:
	if not _drag_active or not _drag_initial_positions.has(_drag_anchor_instance):
		return
	var anchor_start: int = _drag_initial_positions[_drag_anchor_instance]
	var new_start := anchor_start + pixels_to_ticks(mouse_global.x - _drag_press_global.x)
	if not free_move and grid_helper:
		new_start = grid_helper.snap_ticks(new_start)
	# Off the ends of the track list the clips stay on their current track.
	var track_delta := _drag_current_track_delta
	var anchor_index: int = _drag_initial_track_indices.get(_drag_anchor_instance, -1)
	var hover_index := _find_track_index_at_global_position(mouse_global)
	if anchor_index >= 0 and hover_index >= 0:
		track_delta = hover_index - anchor_index
	_drag_to(maxi(0, new_start) - anchor_start, track_delta)


## Place the dragged clips `requested_tick_delta` / `requested_track_delta` from where they started,
## as close as collisions and clip-capable tracks allow.
func _drag_to(requested_tick_delta: int, requested_track_delta: int) -> void:
	var track_delta := _clamp_track_delta(requested_track_delta)
	var tick_delta := _clamp_instances_tick_delta(_drag_selected_instances, requested_tick_delta, track_delta, true)
	if not _drag_placement_is_free(tick_delta, track_delta) and track_delta != _drag_current_track_delta:
		# Clips already sit where the hovered track would put them; slide along the current one.
		track_delta = _drag_current_track_delta
		tick_delta = _clamp_instances_tick_delta(_drag_selected_instances, requested_tick_delta, track_delta, true)
	if not _drag_placement_is_free(tick_delta, track_delta):
		return
	_apply_clip_drag(tick_delta, track_delta)


## True when every dragged clip, offset from where it started, lands on empty space.
func _drag_placement_is_free(tick_delta: int, track_delta: int) -> bool:
	for inst in _drag_selected_instances:
		var origin_index: int = _drag_initial_track_indices.get(inst, -1)
		if not inst or origin_index < 0:
			continue
		var target_index := origin_index + track_delta
		if target_index < 0 or target_index >= timeline_tracks.size():
			return false
		var target: Track = timeline_tracks[target_index].track
		var start := maxi(0, int(_drag_initial_positions[inst]) + tick_delta)
		if target.has_clip_overlap(start, inst.duration_ticks, _drag_selected_instances):
			return false
	return true


func _apply_clip_drag(tick_delta: int, track_delta: int) -> void:
	if tick_delta == _drag_current_tick_delta and track_delta == _drag_current_track_delta:
		return
	var changes_track := track_delta != _drag_current_track_delta
	_drag_current_tick_delta = tick_delta
	_drag_current_track_delta = track_delta
	for inst in _drag_selected_instances:
		var origin_index: int = _drag_initial_track_indices.get(inst, -1)
		if not inst or origin_index < 0:
			continue
		var new_start := maxi(0, int(_drag_initial_positions[inst]) + tick_delta)
		if inst.start_ticks != new_start:
			inst.set_position(new_start)
		var target: Track = timeline_tracks[origin_index + track_delta].track
		if inst.track != target:
			inst.track.remove_clip_instance(inst)
			target.add_clip_instance(inst)
	if changes_track:
		# Removing an instance from its track drops it from the selection.
		clip_selection_manager.select_instances(_drag_selected_instances)
	_redraw_all_tracks()


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
	if _automation_follows_enabled() and _drag_current_tick_delta != 0:
		cmds.append_array(AutomationActions.shift_track_automation(
			_drag_automation_moves(), _drag_current_tick_delta, "Move Automation"
		))
	HistoryUtil.record_many("Move Clips", cmds)

	_reset_drag_state()
	clip_selection_manager.refresh_after_modification()
	queue_redraw()


func _reset_drag_state() -> void:
	_drag_active = false
	_drag_anchor_instance = null
	_drag_origin_clip_ui = null
	_drag_initial_positions.clear()
	_drag_initial_track_indices.clear()
	_drag_selected_instances.clear()
	_drag_current_tick_delta = 0
	_drag_current_track_delta = 0


## "Automation follows clips" (REQ-025): moving a clip also drags the lane points under it. Skip
## cross-track moves - a lane is owned by its track and its target does not travel with the clip.
func _automation_follows_enabled() -> bool:
	return project != null and project.get_arranger_view("automation_follows_clips")


## The dragged clips that moved horizontally on their original track, as
## `{track, start, end}` ranges for `AutomationActions.shift_track_automation`.
func _drag_automation_moves() -> Array:
	var moves: Array = []
	for inst in _drag_selected_instances:
		if not inst or inst.track == null:
			continue
		var old_track_idx: int = _drag_initial_track_indices.get(inst, -1)
		var old_track: Track = null
		if old_track_idx >= 0 and old_track_idx < timeline_tracks.size():
			old_track = timeline_tracks[old_track_idx].track
		if old_track == null or old_track != inst.track:
			continue
		var old_start: int = _drag_initial_positions.get(inst, inst.start_ticks)
		moves.append({"track": old_track, "start": old_start, "end": old_start + inst.duration_ticks})
	return moves


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
			if not target_track_node.track.has_clips():
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


# ============================================================================
# AUTOMATION RANGE OPERATIONS (REQ-021)
# ============================================================================
# The four clipboard operations are shared between clips and automation points. The automation
# path wins whenever points are the active selection; otherwise nothing changes for clips.

## True when cut/copy/paste/duplicate should act on automation points rather than clips: the
## user last worked in a lane row. Any clip interaction calls `release()`, which ends this.
func _automation_is_active() -> bool:
	return automation_selection_manager != null and (
		automation_selection_manager.focus_lane != null
		or automation_selection_manager.has_selection()
		or automation_selection_manager.get_full_range() != Vector2i.ZERO
	)


## Copy the active point range/selection. Returns false when there was nothing to copy.
func _automation_copy() -> bool:
	return automation_selection_manager.copy()


func _automation_cut() -> void:
	var operand := automation_selection_manager.get_operand()
	if operand.is_empty() or operand["points"].is_empty():
		logger.warn("Cut skipped - no automation points selected")
		return
	if not automation_selection_manager.copy():
		return
	AutomationActions.delete_points(operand["lane"], operand["points"])
	automation_selection_manager.clear_selection()
	logger.info("Cut %d automation point(s)" % operand["points"].size())


## Paste the point clipboard into the active lane at the anchor (range start, else last click,
## else the playhead), matching the clip paste anchor conventions.
func _automation_paste() -> void:
	if not automation_selection_manager.has_clipboard():
		logger.warn("Paste skipped - automation clipboard empty")
		return
	var lane := automation_selection_manager.get_target_lane()
	if lane == null:
		logger.warn("Paste skipped - no automation lane is active")
		return
	var playhead_ticks: int = Sonara.editor.playhead_ticks if Sonara and Sonara.editor else 0
	var target_tick := automation_selection_manager.get_paste_tick(playhead_ticks)
	var pasted := AutomationActions.paste_segment(lane, automation_selection_manager.clipboard_specs_at(target_tick))
	_select_pasted_points(lane, pasted)
	logger.info("Pasted %d automation point(s) at tick %d" % [pasted.size(), target_tick])


## Duplicate the active range/selection immediately after itself, as clip duplicate does.
func _automation_duplicate() -> void:
	var operand := automation_selection_manager.get_operand()
	if operand.is_empty() or operand["points"].is_empty():
		return
	var previous: Dictionary = automation_selection_manager.clipboard
	if not automation_selection_manager.copy():
		return
	var lane: AutomationLane = operand["lane"]
	var target_tick := automation_selection_manager.get_duplicate_tick(int(operand["origin"]) + int(operand["length"]))
	var pasted := AutomationActions.paste_segment(
		lane, automation_selection_manager.clipboard_specs_at(target_tick), "Duplicate Points"
	)
	# Duplicate is not a copy: leave whatever was on the clipboard before untouched.
	automation_selection_manager.clipboard = previous
	_select_pasted_points(lane, pasted)
	logger.info("Duplicated %d automation point(s) at tick %d" % [pasted.size(), target_tick])


## Leave the freshly pasted points selected so a following duplicate chains off them.
func _select_pasted_points(lane: AutomationLane, pasted: Array) -> void:
	if pasted.is_empty():
		return
	var ids: Array = []
	for point in pasted:
		ids.append(point.id)
	automation_selection_manager.hide_range()
	automation_selection_manager.select_ids(lane, ids)


## Delete the selected automation points (REQ-018). Returns false when there was no selection.
func delete_automation_selection() -> bool:
	if automation_selection_manager == null or not automation_selection_manager.has_selection():
		return false
	var lane := automation_selection_manager.lane
	var points := automation_selection_manager.get_selected_points()
	if points.is_empty():
		return false
	AutomationActions.delete_points(lane, points)
	automation_selection_manager.clear_selection()
	return true


func copy_selection_to_clipboard() -> void:
	if _automation_is_active():
		_automation_copy()
		return
	if not clip_selection_manager or not clip_selection_manager.has_selection():
		clip_clipboard = null
		logger.warn("Copy skipped - no clips selected")
		return
	clip_clipboard = clip_selection_manager.selection.clone()
	_apply_time_range_to_clipboard(clip_clipboard)
	logger.info("Copied %d clips to clipboard" % clip_clipboard.clip_instances.size())


func cut_selection_to_clipboard() -> void:
	if _automation_is_active():
		_automation_cut()
		return
	if not clip_selection_manager or not clip_selection_manager.has_selection():
		clip_clipboard = null
		logger.warn("Cut skipped - no clips selected")
		return
	clip_clipboard = clip_selection_manager.selection.clone()
	_apply_time_range_to_clipboard(clip_clipboard)
	var selected = clip_selection_manager.get_selected_instances()
	var cmds: Array[Command] = []
	for inst in selected:
		if inst and inst.track:
			cmds.append(ClipInstanceDeleteCommand.new(inst.track, inst))
	HistoryUtil.execute_many("Cut Clips", cmds)
	clip_selection_manager.clear_selection()
	logger.info("Cut %d clips to clipboard" % selected.size())


## Paste clipboard clips at the last clicked location (range start, clicked tick, or playhead)
## onto the last clicked track. Refuses if they would overlap or run past the last track.
func paste_clipboard() -> void:
	if _automation_is_active():
		_automation_paste()
		return
	var playhead_ticks := Sonara.editor.playhead_ticks if Sonara and Sonara.editor else 0
	var target_tick := clip_selection_manager.get_paste_tick(playhead_ticks) if clip_selection_manager else playhead_ticks
	var target_track: Track = clip_selection_manager.anchor_track if clip_selection_manager else null
	if clip_clipboard == null or clip_clipboard.is_empty():
		logger.warn("Paste skipped - clipboard empty")
		return
	if _plan_placement(clip_clipboard, target_tick, target_track).is_empty():
		logger.warn("Paste skipped - clips would run past the last track")
		return
	if _clipboard_placement_blocked(clip_clipboard, target_tick, target_track):
		logger.warn("Paste skipped - no adequate space")
		return
	var new_instances = paste_clipboard_at(target_tick, null, true, "Paste", target_track)
	if new_instances.is_empty():
		logger.warn("Paste skipped - clipboard empty")
	else:
		logger.info("Pasted %d clips at tick %d" % [new_instances.size(), target_tick])


## Insert `source` (or the clipboard) at `target_tick`, with the topmost clip on `target_track`
## (null keeps each clip's own track). Returns [] when blocked or empty.
func paste_clipboard_at(target_tick: int, selection_source: ClipSelection = null, update_selection: bool = true, action_name: String = "Paste", target_track: Track = null, copy_automation: bool = false) -> Array[ClipInstance]:
	if not Sonara.editor or not Sonara.editor.project:
		push_warning("[Timeline] Cannot paste clips - no active project")
		return []

	var source := selection_source
	if source == null:
		source = clip_clipboard

	if source == null or source.is_empty():
		return []

	if _clipboard_placement_blocked(source, target_tick, target_track):
		return []

	var new_instances: Array[ClipInstance] = []
	var cmds: Array[Command] = []
	var automation_copies: Array = []
	for placement in _plan_placement(source, target_tick, target_track):
		var original_inst: ClipInstance = placement.instance
		var dest_track: Track = placement.track
		var new_start: int = placement.start
		var clip_ref: Clip = original_inst.clip
		var new_instance := ClipInstance.new("", clip_ref.id)
		new_instance.clip = clip_ref
		new_instance.start_ticks = new_start
		new_instance.duration_ticks = original_inst.duration_ticks
		new_instance.copy_overrides_from(original_inst)
		new_instances.append(new_instance)

		var cmd := ClipInstanceCreateCommand.new(
			dest_track, clip_ref, new_start, original_inst.duration_ticks,
			null, false, new_instance
		)
		cmd.name = "%s Clip" % action_name
		cmds.append(cmd)
		# A lane belongs to its track, so automation only travels with copies on the same track.
		if copy_automation and dest_track == original_inst.track:
			automation_copies.append({
				"track": dest_track,
				"start": original_inst.start_ticks,
				"end": original_inst.start_ticks + original_inst.duration_ticks,
				"delta": new_start - original_inst.start_ticks,
			})

	if new_instances.is_empty():
		return []

	if not automation_copies.is_empty() and _automation_follows_enabled():
		cmds.append_array(AutomationActions.copy_track_automation_commands(automation_copies, "%s Automation" % action_name))

	HistoryUtil.execute_many("%s Clips" % action_name, cmds)

	if update_selection and clip_selection_manager:
		clip_selection_manager.select_instances(new_instances)
		clip_selection_manager.refresh_after_modification()

	_refresh_tracks_for_instances(new_instances)
	return new_instances


## Duplicate selected clips at the selection end. Refuses if they would overlap.
func duplicate_selection() -> void:
	if _automation_is_active():
		_automation_duplicate()
		return
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
		logger.warn("Duplicate skipped - no adequate space")
		return
	var new_instances = paste_clipboard_at(target_tick, selection_clone, true, "Duplicate", null, true)
	clip_clipboard = previous_clipboard if previous_clipboard else selection_clone

	if not new_instances.is_empty():
		logger.info("Duplicated %d clips starting at %d" % [new_instances.size(), target_tick])


## True when placing `source` at `target_tick` / `target_track` would overlap an existing clip.
func _clipboard_placement_blocked(source: ClipSelection, target_tick: int, target_track: Track = null) -> bool:
	for placement in _plan_placement(source, target_tick, target_track):
		var inst: ClipInstance = placement.instance
		var dest_track: Track = placement.track
		if dest_track.has_clip_overlap(placement.start, inst.duration_ticks):
			return true
	return false


## Where each clip in `source` lands: [{instance, track, start}]. With a clip-capable `target_track`,
## the topmost source track maps onto it and the others keep their lane spacing (folders skipped).
## Returns [] when nothing is placeable or the layout would run past the last lane.
func _plan_placement(source: ClipSelection, target_tick: int, target_track: Track = null) -> Array[Dictionary]:
	var plan: Array[Dictionary] = []
	if source == null or source.is_empty():
		return plan

	var lanes: Array[Track] = []
	for lane in timeline_tracks:
		if lane and lane.track and lane.track.has_clips():
			lanes.append(lane.track)
	var target_index := lanes.find(target_track) if target_track else -1
	var instances := source.get_sorted_by_start()

	var top_index := -1
	for inst in instances:
		if inst and inst.clip and inst.track:
			var index := lanes.find(inst.track)
			if index >= 0 and (top_index < 0 or index < top_index):
				top_index = index
	var track_delta := target_index - top_index if target_index >= 0 and top_index >= 0 else 0

	var delta_ticks := target_tick - source.start_tick
	for inst in instances:
		if not inst or not inst.clip or not inst.track:
			continue
		var dest_track: Track = inst.track
		var source_index := lanes.find(inst.track)
		if track_delta != 0 and source_index >= 0:
			var dest_index := source_index + track_delta
			if dest_index < 0 or dest_index >= lanes.size():
				plan.clear()
				return plan
			dest_track = lanes[dest_index]
		if not dest_track.has_clips():
			continue
		plan.append({
			"instance": inst,
			"track": dest_track,
			"start": maxi(0, inst.start_ticks + delta_ticks),
		})
	return plan


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
	var cmds: Array[Command] = []
	var moves: Array = []
	for inst in selected:
		if not inst:
			continue
		var old_start: int = inst.start_ticks
		var new_start = max(0, inst.start_ticks + clamped_delta)
		if new_start == old_start:
			continue
		inst.set_position(new_start)
		cmds.append(ClipInstanceTransformCommand.new(
			"Move Clip", inst,
			old_start, inst.duration_ticks, inst.clip_offset,
			new_start, inst.duration_ticks, inst.clip_offset
		))
		if inst.track != null:
			moves.append({"track": inst.track, "start": old_start, "end": old_start + inst.duration_ticks})
		var track_ui = _get_timeline_track_for_instance(inst)
		if track_ui and not tracks_to_refresh.has(track_ui):
			tracks_to_refresh.append(track_ui)
	for track_ui in tracks_to_refresh:
		if track_ui:
			track_ui._update_clip_positions()
	if _automation_follows_enabled() and not moves.is_empty():
		cmds.append_array(AutomationActions.shift_track_automation(moves, clamped_delta, "Move Automation"))
	HistoryUtil.record_many("Move Clips", cmds)
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

	var old_starts: Dictionary = {}
	var old_tracks: Dictionary = {}
	for inst in selected:
		if inst:
			old_starts[inst] = inst.start_ticks
			old_tracks[inst] = inst.track

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

	var cmds: Array[Command] = []
	for inst in selected:
		if not inst:
			continue
		var old_start: int = old_starts.get(inst, inst.start_ticks)
		var old_track: Track = old_tracks.get(inst, null)
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
	HistoryUtil.record_many("Move Clips", cmds)

	clip_selection_manager.select_instances(selected)
	clip_selection_manager.refresh_after_modification()
	_refresh_tracks_for_instances(selected)
	queue_redraw()
	logger.info("Moved selection by %d track(s)" % allowed_delta)


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
## Double-click on a MIDI clip: select only it and open it in the clip editor.
func _on_clip_open_in_editor_requested(clip_ui: TimelineClip) -> void:
	var instance := clip_ui.clip_instance if clip_ui else null
	if not instance or not instance.clip or instance.clip.type != Clip.ClipType.MIDI:
		return
	if clip_selection_manager:
		clip_selection_manager.select_only(instance)
	if Sonara.editor:
		Sonara.editor.show_clip_editor()


func _on_clip_context_menu_requested(clip_ui: TimelineClip, mouse_pos_global: Vector2) -> void:
	if not clip_ui or not clip_ui.clip_instance or not is_instance_valid(clip_ctx_menu):
		return
	# Determine selection to bind: use current selection if it contains the clicked instance; otherwise just the clicked
	var selection := get_selected_clip_instances()
	if selection.is_empty() or not selection.has(clip_ui.clip_instance):
		selection = [clip_ui.clip_instance]
	clip_ctx_menu.bind_to_instances(selection)
	# Split lands where the user clicked, snapped to the grid.
	var local_x := (get_global_transform().affine_inverse() * mouse_pos_global).x
	var click_ticks := pixels_to_ticks(local_x)
	clip_ctx_menu.split_tick = grid_helper.snap_ticks(click_ticks) if grid_helper else click_ticks
	# Dock above or below the clip, inside the visible arranger area, so the clip stays visible.
	var bounds := get_viewport_rect()
	var scroll_parent := get_parent()
	if scroll_parent is Control:
		bounds = bounds.intersection(scroll_parent.get_global_rect())
	clip_ctx_menu.popup_docked(clip_ui.get_global_rect(), bounds, mouse_pos_global.x, mouse_pos_global.y)


## Split the clip bound to the context menu at the position that was clicked. One undo step.
func _on_clip_split_requested(instances: Array[ClipInstance]) -> void:
	var at: int = clip_ctx_menu.split_tick
	var cmds: Array[Command] = []
	for inst in instances:
		if inst == null or inst.track == null or at <= inst.start_ticks or at >= inst.get_end_ticks():
			continue
		var tail := ClipRangeActions.piece(inst, at, inst.get_end_ticks())
		if inst.loop_enabled:
			tail.clip_offset = inst.wrap_content_tick(tail.clip_offset)
		var head_duration: int = at - inst.start_ticks
		var create := ClipInstanceCreateCommand.new(inst.track, inst.clip, tail.start_ticks, tail.duration_ticks, null, false, tail)
		var trim := ClipInstanceTransformCommand.new(
			"Split Clip", inst,
			inst.start_ticks, inst.duration_ticks, inst.clip_offset,
			inst.start_ticks, head_duration, inst.clip_offset)
		create.do()
		trim.do()
		cmds.append(create)
		cmds.append(trim)
	HistoryUtil.record_many("Split Clip", cmds)


## Merge the instances bound to the context menu, per track, and select the results. One undo step.
func _on_clip_merge_requested(instances: Array[ClipInstance]) -> void:
	if not Sonara.editor or not Sonara.editor.project:
		return
	var merged := ClipMergeActions.merge(Sonara.editor.project, instances)
	if merged.is_empty():
		return
	if clip_selection_manager:
		clip_selection_manager.select_instances(merged)
		clip_selection_manager.refresh_after_modification()
	_refresh_tracks_for_instances(merged)
	logger.info("Merged clips into %d instance(s)" % merged.size())


## Cut the instances bound to the context menu (may not match the live selection if the clicked clip was unselected).
func _on_clip_cut_requested(instances: Array[ClipInstance]) -> void:
	if not instances or instances.is_empty() or not clip_selection_manager:
		return
	clip_selection_manager.select_instances(instances)
	cut_selection_to_clipboard()


## Copy the instances bound to the context menu (may not match the live selection if the clicked clip was unselected).
func _on_clip_copy_requested(instances: Array[ClipInstance]) -> void:
	if not instances or instances.is_empty() or not clip_selection_manager:
		return
	clip_selection_manager.select_instances(instances)
	copy_selection_to_clipboard()


func _on_clip_delete_requested(instances: Array[ClipInstance]) -> void:
	if not instances or instances.is_empty():
		return
	var cmds: Array[Command] = []
	for inst in instances:
		if inst and inst.track:
			cmds.append(ClipInstanceDeleteCommand.new(inst.track, inst))
	if cmds.is_empty():
		return
	HistoryUtil.execute_many("Delete Clips", cmds)


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
	HistoryUtil.execute_many("Make Clips Unique", cmds)



## Content x range currently inside the scroll viewport.
func get_visible_x_range() -> Vector2:
	var start_x := 0.0
	if grid_helper:
		start_x = clampf(grid_helper.scroll_position, 0.0, size.x)
	return Vector2(start_x, clampf(start_x + get_viewport_width(), 0.0, size.x))


func _draw() -> void:
	_draw_row_backgrounds()
	if not clip_selection_manager:
		return

	var theme_fill = Color(1, 1, 1, 0.1)
	var theme_stroke = Color(1, 1, 1, 0.4)

	if clip_selection_manager.is_box_selecting and clip_selection_manager.box_rect.size.length() > 0:
		var rect := clip_selection_manager.box_rect.abs()
		draw_rect(rect, theme_fill, true)
		draw_rect(rect, theme_stroke, false, 2.0)


## Every row's fill, the grid, then every row's bottom border, in one pass beneath the rows.
## Only the visible x range is drawn, so a horizontal scroll redraws this one canvas item; a
## vertical scroll redraws nothing. Children draw on top: clips over track lanes, curves and
## points over automation lanes.
func _draw_row_backgrounds() -> void:
	var visible_x := get_visible_x_range()
	if visible_x.y <= visible_x.x:
		return
	var width := visible_x.y - visible_x.x
	var rows_bottom := 0.0
	for child in get_children():
		var row := child as Control
		if row == null or not row.visible:
			continue
		if row is TimelineTrack:
			draw_rect(Rect2(visible_x.x, row.position.y, width, row.size.y), row.get_lane_color(), true)
		elif row is AutomationLaneRow:
			# The automation header's darker tint of the track color, so row and header match.
			draw_rect(Rect2(visible_x.x, row.position.y, width, row.size.y), row.get_lane_color(), true)
		else:
			continue
		rows_bottom = maxf(rows_bottom, row.position.y + row.size.y)

	if grid_helper:
		_draw_grid_lines(visible_x.x, visible_x.y, rows_bottom)

	for child in get_children():
		var row := child as Control
		if row == null or not row.visible:
			continue
		if row is TimelineTrack:
			var thickness: float = row.border_thickness
			if thickness > 0:
				draw_rect(Rect2(visible_x.x, row.position.y + row.size.y - thickness, width, thickness), row.border_color, true)
		elif row is AutomationLaneRow:
			var y: float = row.position.y + row.size.y - 1.0
			draw_line(Vector2(visible_x.x, y), Vector2(visible_x.y, y), row.border_color, 1.0)


## Vertical grid lines between content x `start_x` and `end_x`, from the top down to `bottom`.
## Content coordinates: the timeline scrolls inside a ScrollContainer, so no scroll offset applies.
func _draw_grid_lines(start_x: float, end_x: float, bottom: float) -> void:
	if end_x <= start_x or bottom <= 0.0:
		return
	for line in grid_helper.get_visible_grid_lines(start_x, end_x, 0.0, false):
		var x: float = line.x
		if x < start_x or x > end_x:
			continue
		match line.type:
			GridHelper.GridLineType.BAR:
				draw_line(Vector2(x, 0.0), Vector2(x, bottom), grid_color_bar, 2.0)
			GridHelper.GridLineType.BEAT:
				draw_line(Vector2(x, 0.0), Vector2(x, bottom), grid_color_beat, 1.0)
			GridHelper.GridLineType.SUBDIVISION:
				draw_line(Vector2(x, 0.0), Vector2(x, bottom), grid_color_tick, 1.0)


func _on_clip_selection_changed(instances: Array[ClipInstance]) -> void:
	# Selecting clips hands the clipboard shortcuts back to the clips (see `_automation_is_active`).
	if not instances.is_empty():
		automation_selection_manager.release()
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
