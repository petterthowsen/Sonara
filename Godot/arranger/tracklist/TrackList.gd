# TrackList.gd
# Container for TrackItem UI elements
# Listens to Editor signals and creates/removes TrackItems accordingly

class_name TrackList extends VBoxContainer

## Owns arranger track-header selection: multi-select, active track, and visual updates.

var logger : Log = Log.make("TrackList")

# Scene to instantiate for each track
const track_item_scene: PackedScene = preload("res://arranger/tracklist/TrackItem.tscn")

# context menu to show when right-clicking empty area
@onready var context_menu: TrackListContextMenu = $TrackListContextMenu

# context menu when right-clicking a trackitem
@onready var track_item_context_menu: TrackItemContextMenu = $TrackItemContextMenu

# Track items indexed by track index
var track_items: Array[TrackItem] = []

## Automation lane header rows, keyed by the AutomationLane they show. Rows live as direct
## children of this VBox so AutomationRowOrder can interleave them with the TrackItems.
var _lane_headers: Dictionary = {}

## Lazily created popups (REQ-014, REQ-015).
var _lane_menu: AutomationLaneMenu = null
var _parameter_picker: AutomationParameterPicker = null

# Current project reference
var current_project: Project = null

# Header selection: last selected track is active.
var selected_tracks: Array[Track] = []
var active_track: Track = null
var _selection_anchor: Track = null
var _is_rebuilding: bool = false

## Color of the track drag insert line and folder header glow.
@export var drop_indicator_color := DropIndicator.DEFAULT_COLOR

## Glowing track drag overlay (top-level, so it never takes layout space), created on first use.
var _drop_indicator: DropIndicator = null

## Pixels per folder nesting level; matches TrackItem indent.
@export var folder_indent_pixels: int = 12

signal selection_changed(tracks: Array[Track], active: Track)

## Rows from the last _update_visual_order, resized on every fold animation step.
var _fold_rows: Array = []

func _ready():
	# remove any nodes
	for child in get_children():
		if child is TrackItem or child is AutomationLaneHeader:
			child.free()
	
	# Ensure TrackList fills parent so empty areas can receive drops
	size_flags_vertical = Control.SIZE_FILL | Control.SIZE_EXPAND
	
	# Connect to Editor signals for project lifecycle
	if Sonara and Sonara.editor:
		Sonara.editor.project_activated.connect(_on_project_activated)
		Sonara.editor.project_closed.connect(_on_project_closed)

	# Enable drag and drop
	set_drag_forwarding(Callable(self, "_get_drag_data"), Callable(self, "_can_drop_data"), Callable(self, "_drop_data"))
	set_process(false)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		context_menu.popup(Rect2(get_global_mouse_position() - Vector2.ONE * 10, Vector2.ZERO))
		# force grab focus to the context menu
		context_menu.grab_focus()
		accept_event()


## Track the drop indicator only while a track drag is in progress.
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_BEGIN:
		set_process(DragDrop.current_drag(self) is TrackDrag)
	elif what == NOTIFICATION_DRAG_END:
		set_process(false)
		DropIndicator.hide_indicator(_drop_indicator)


## Escape cancels a track drag; nothing moved, so there is nothing to restore.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and DragDrop.current_drag(self) is TrackDrag:
		get_viewport().gui_cancel_drag()
		accept_event()


## Show where a track drag lands.
func _process(_delta: float) -> void:
	var data: Variant = DragDrop.current_drag(self)
	if not data is TrackDrag:
		DropIndicator.hide_indicator(_drop_indicator)
		return
	var target := TrackDropTarget.resolve(self, data as TrackDrag, get_global_mouse_position())
	if not target.is_valid():
		DropIndicator.hide_indicator(_drop_indicator)
		return
	_drop_indicator = DropIndicator.place(self, _drop_indicator, target.indicator_rect, target.is_nest(), drop_indicator_color)


# ============================================================================
# EDITOR/PROJECT SIGNAL CALLBACKS
# ============================================================================
func _on_project_activated(project: Project) -> void:
	"""Called when a project is activated - bind to its signals and sync UI."""
	# Clean up old connections and items if any (re-activation without a close)
	if current_project:
		_unbind_from_project()
		_clear_selection(false)
		_clear_all_track_items()

	current_project = project

	# Connect to project's track signals
	current_project.track_added.connect(_on_track_added)
	current_project.track_removed.connect(_on_track_removed)
	current_project.tracks_layout_changed.connect(_on_tracks_layout_changed)

	# Sync UI with existing tracks without treating each as a user selection
	_is_rebuilding = true
	for i in range(current_project.tracks.size()):
		_on_track_added(current_project.tracks[i])
	# Sibling `order` is not global; rebuild visual order from the folder hierarchy.
	_update_visual_order()
	_is_rebuilding = false

	var visual_tracks := _get_visual_tracks()
	if not visual_tracks.is_empty():
		_select_track(visual_tracks[0], false, false, false)

	logger.info("Project activated: ", project.project_name)


func _on_project_closed() -> void:
	"""Clear all track items when project closes."""
	if current_project:
		_unbind_from_project()

	_clear_selection(false)
	_clear_all_track_items()

	current_project = null


func _unbind_from_project() -> void:
	"""Disconnect from current project signals."""
	if current_project:
		if current_project.track_added.is_connected(_on_track_added):
			current_project.track_added.disconnect(_on_track_added)
		if current_project.track_removed.is_connected(_on_track_removed):
			current_project.track_removed.disconnect(_on_track_removed)
		if current_project.tracks_layout_changed.is_connected(_on_tracks_layout_changed):
			current_project.tracks_layout_changed.disconnect(_on_tracks_layout_changed)


func _on_track_added(track: Track) -> void:
	"""Create a TrackItem UI element for the new track."""
	if track_item_scene == null:
		push_warning("[TrackList] No track_item_scene assigned")
		return

	# Find track index in the project
	var index = current_project.tracks.find(track)
	if index < 0:
		push_error("[TrackList] Track not found in project")
		return

	# Instantiate TrackItem
	var track_item = track_item_scene.instantiate() as TrackItem
	if track_item == null:
		push_error("[TrackList] Failed to instantiate TrackItem")
		return

	# Append; visual order is applied from the folder hierarchy after add/rebuild.
	add_child(track_item)

	# Bind to track data and pass project reference for channel lookup
	track_item.bind_to_track(track, index, current_project)
	
	# Connect to track signals for reordering / folder reparent
	track.order_changed.connect(_on_track_layout_changed)
	track.parent_changed.connect(_on_track_layout_changed)
	
	# Connect to track item signals
	track_item.right_clicked.connect(_on_track_item_right_clicked)
	track_item.select_requested.connect(_on_track_item_select_requested)
	track_item.rename_tab_requested.connect(_on_track_item_rename_tab_requested)
	track_item.automation_disclosure_toggled.connect(_on_automation_disclosure_toggled)
	track_item.automation_menu_requested.connect(_on_automation_menu_requested)

	# Automation lane rows follow the track's lanes and its disclosure state.
	track.automation_lane_added.connect(_on_automation_lane_added.bind(track))
	track.automation_lane_removed.connect(_on_automation_lane_removed.bind(track))
	track.automation_expanded_changed.connect(_on_automation_expanded_changed.bind(track))
	track.folder_expanded_changed.connect(_on_folder_expanded_changed.bind(track))
	_rebuild_lane_headers(track)

	# Store reference
	if index >= track_items.size():
		track_items.resize(index + 1)
	track_items[index] = track_item

	logger.info("Track added: ", track.name, " at index ", index, " with order ", track.order)

	if not _is_rebuilding:
		_update_visual_order()
		_select_track(track, false, false)


func _on_track_removed(track: Track) -> void:
	"""Remove the TrackItem UI element for the removed track."""
	var track_item = _find_track_item(track)
	if not track_item:
		push_warning("[TrackList] Track item not found for removed track: %s" % track.name)
		return
	
	_disconnect_track_layout_signals(track)
	_clear_lane_headers(track)

	_remove_track_from_selection(track)
	
	# Remove from track_items array
	var index = track_items.find(track_item)
	if index >= 0:
		track_items.remove_at(index)
	
	# Remove from scene tree and free
	track_item.queue_free()
	
	logger.info("Track item removed for: ", track.name)


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
	for connection in track.automation_lane_removed.get_connections():
		if connection["callable"].get_object() == self:
			track.automation_lane_removed.disconnect(connection["callable"])
	for connection in track.automation_expanded_changed.get_connections():
		if connection["callable"].get_object() == self:
			track.automation_expanded_changed.disconnect(connection["callable"])
	for connection in track.folder_expanded_changed.get_connections():
		if connection["callable"].get_object() == self:
			track.folder_expanded_changed.disconnect(connection["callable"])


## Rebuild UI order when a track's sibling order or folder parent changes.
func _on_track_layout_changed(_unused: int) -> void:
	if not current_project or current_project.is_track_layout_batching():
		return
	_update_visual_order()


## Rebuild after a batched reorder so headers stay aligned with the timeline.
func _on_tracks_layout_changed() -> void:
	if not current_project:
		return
	_update_visual_order()


func _on_track_item_select_requested(track: Track, additive: bool, range_select: bool) -> void:
	"""Handle Ctrl/Shift/plain clicks on a TrackItem header."""
	_select_track(track, additive, range_select)


## After a rename Tab, select the adjacent track and start editing its name.
func _on_track_item_rename_tab_requested(track: Track, reverse: bool) -> void:
	if track == null:
		return
	var visual := _get_visual_tracks()
	var index := visual.find(track)
	if index < 0:
		return
	var next_index := index + (-1 if reverse else 1)
	if next_index < 0 or next_index >= visual.size():
		return
	var next_track := visual[next_index]
	_select_track(next_track, false, false)
	var item := _find_track_item(next_track)
	if item:
		_ensure_track_item_visible(item)
		item.begin_rename.call_deferred()


func _on_track_item_right_clicked(track: Track, mouse_position: Vector2) -> void:
	"""Show context menu when a track item is right-clicked."""
	if not track or not track_item_context_menu:
		return
	
	logger.info("Track item right-clicked: ", track.name)

	if not selected_tracks.has(track):
		_select_track(track, false, false)
	
	# Bind the context menu to the selection (the right-clicked track is in it)
	track_item_context_menu.bind_tracks(selected_tracks, track, current_project)
	
	# Show the context menu at the mouse position
	track_item_context_menu.popup(Rect2(mouse_position - Vector2.ONE * 10, Vector2.ZERO))
	track_item_context_menu.grab_focus()


# ============================================================================
# INTERNAL HELPERS
# ============================================================================

func _clear_all_track_items() -> void:
	"""Remove all track items."""
	for track_item in track_items:
		if track_item is TrackItem:
			_clear_lane_headers(track_item.track)
			_disconnect_track_layout_signals(track_item.track)
			track_item.queue_free()
	
	track_items.clear()
	for header in _lane_headers.values():
		if is_instance_valid(header):
			header.queue_free()
	_lane_headers.clear()
	

# ============================================================================
# TRACK SELECTION
# ============================================================================

## Apply header selection. Last selected track becomes active.
func _select_track(track: Track, additive: bool, range_select: bool, apply_record_arm: bool = true) -> void:
	if track == null:
		return
	# Selecting a track hidden inside a collapsed folder (e.g. from the mixer) unfolds it.
	if current_project:
		current_project.reveal_track(track)

	if range_select:
		if _selection_anchor == null:
			_selection_anchor = active_track if active_track else track
		var range_tracks := _tracks_in_visual_range(_selection_anchor, track)
		if additive:
			for t in range_tracks:
				if not selected_tracks.has(t):
					selected_tracks.append(t)
		else:
			selected_tracks = range_tracks
		active_track = track
	elif additive:
		if selected_tracks.has(track):
			selected_tracks.erase(track)
			if active_track == track:
				active_track = selected_tracks.back() if not selected_tracks.is_empty() else null
		else:
			selected_tracks.append(track)
			active_track = track
		_selection_anchor = track
	elif selected_tracks.has(track) and selected_tracks.size() > 1:
		# Clicking an already-selected header keeps the multi-select so a drag
		# can move the whole block; this track becomes active.
		active_track = track
		_selection_anchor = track
	else:
		selected_tracks.clear()
		selected_tracks.append(track)
		active_track = track
		_selection_anchor = track

	_refresh_selection_visuals()
	_notify_editor(apply_record_arm)
	selection_changed.emit(selected_tracks, active_track)


## Replace the selection without emitting selection_changed (selection mirrored from the mixer).
## Tracks inside collapsed folders are unfolded so the selection is visible.
func set_selection_silent(tracks: Array[Track], active: Track) -> void:
	selected_tracks.clear()
	for t in tracks:
		if t and not selected_tracks.has(t):
			selected_tracks.append(t)
			if current_project:
				current_project.reveal_track(t)
	active_track = active if selected_tracks.has(active) else null
	_selection_anchor = active_track
	_refresh_selection_visuals()
	var item := _find_track_item(active_track) if active_track else null
	if item:
		_ensure_track_item_visible(item)


## Drop a track from the current selection, keeping another selected track active if possible.
func _remove_track_from_selection(track: Track) -> void:
	if track == null:
		return
	var changed := false
	if selected_tracks.has(track):
		selected_tracks.erase(track)
		changed = true
	if _selection_anchor == track:
		_selection_anchor = selected_tracks.back() if not selected_tracks.is_empty() else null
	if active_track == track:
		active_track = selected_tracks.back() if not selected_tracks.is_empty() else null
		changed = true
	if changed:
		_refresh_selection_visuals()
		_notify_editor(true)
		selection_changed.emit(selected_tracks, active_track)


## Clear header selection without requiring a replacement track.
func _clear_selection(notify: bool = true) -> void:
	selected_tracks.clear()
	active_track = null
	_selection_anchor = null
	_refresh_selection_visuals()
	if notify:
		_notify_editor(false)
		selection_changed.emit(selected_tracks, active_track)


## Push the current selection to Editor so DeviceLane and record-arm follow the active track.
func _notify_editor(apply_record_arm: bool) -> void:
	if Sonara and Sonara.editor:
		Sonara.editor.set_track_selection(selected_tracks, active_track, apply_record_arm)


## Paint each TrackItem as unselected, selected, or active.
func _refresh_selection_visuals() -> void:
	for child in get_children():
		if child is TrackItem:
			var item := child as TrackItem
			if item.track == null:
				continue
			var selected := selected_tracks.has(item.track)
			item.set_selection_state(selected, item.track == active_track)


## Visual top-to-bottom order of tracks currently shown in the list.
func _get_visual_tracks() -> Array[Track]:
	var result: Array[Track] = []
	for child in get_children():
		if child is TrackItem:
			var item := child as TrackItem
			if item.track and item.visible:
				result.append(item.track)
	return result


## Inclusive visual range between two tracks, used for Shift+click.
func _tracks_in_visual_range(from_track: Track, to_track: Track) -> Array[Track]:
	var visual := _get_visual_tracks()
	var a := visual.find(from_track)
	var b := visual.find(to_track)
	var result: Array[Track] = []
	if a < 0 or b < 0:
		if to_track:
			result.append(to_track)
		return result
	if a > b:
		var tmp := a
		a = b
		b = tmp
	for i in range(a, b + 1):
		result.append(visual[i])
	return result


# ============================================================================
# DRAG AND DROP
# ============================================================================

## Unused; TrackList starts drags from TrackItem, not empty space.
func _get_drag_data(_at_position: Vector2) -> Variant:
	return null


## Accept a track drag (resolved from the pointer) or device/SFZ asset drops.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not current_project:
		return false

	if data is TrackDrag:
		return can_drop_track_drag(data as TrackDrag)

	# Check if data is a single asset
	if data is Asset:
		if data.type == Asset.TYPE.Device or data.type == Asset.TYPE.SFZ:
			return true
	
	# Check if data is an array of assets
	if data is Array:
		for item in data:
			if not item is Asset:
				return false
			if item.type != Asset.TYPE.Device and item.type != Asset.TYPE.SFZ:
				return false
		return data.size() > 0

	return false


## Handle dropping a reordered track or device/SFZ assets on the tracklist.
func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not current_project:
		return

	if data is TrackDrag:
		drop_track_drag(data as TrackDrag)
		return
	
	# Handle array of assets
	if data is Array:
		logger.info("Dropping %d assets" % data.size())
		for asset in data:
			if asset is Asset:
				_handle_single_asset_drop(asset)
		return
	
	# Handle single asset
	if data is Asset:
		_handle_single_asset_drop(data)


## Instruments and SFZ files get a new instrument track; effects go on the active (or first) track.
func _handle_single_asset_drop(asset: Asset) -> void:
	if DeviceDropUtil.creates_instrument_track(asset):
		DeviceDropUtil.create_instrument_track_for_asset(current_project, asset)
		return
	if asset.type != Asset.TYPE.Device:
		return
	var device := AssetService.get_device(asset.path)
	if device == null:
		push_error("[TrackList] Failed to get device: ", asset.path)
		return
	if device.category == Device.DeviceCategory.Effect or device.category == Device.DeviceCategory.Utility:
		_add_effect_to_track(asset)
	else:
		push_warning("[TrackList] No drop handler for %s (%s)" % [device.name, device.get_category_string()])


## Add an effect to the active (or first) track's channel, or to a new bus when there is none.
func _add_effect_to_track(asset: Asset) -> void:
	var target_track: Track = active_track
	if target_track == null and current_project.tracks.size() > 0:
		target_track = current_project.tracks[0] as Track
	var target_channel: Channel = null
	if target_track:
		target_channel = current_project.get_channel_by_id(target_track.default_channel_id)
	if target_channel == null:
		target_channel = current_project.create_bus_channel(asset.get_display_name())
		if target_channel == null:
			push_error("[TrackList] Failed to create bus channel")
			return
	if DeviceDropUtil.can_drop_asset_on_channel(target_channel, asset):
		DeviceDropUtil.drop_asset(target_channel, asset, -1, null)


# ============================================================================
# TRACK REORDERING
# ============================================================================

## Roots to move when dragging `source`: the selection if it includes `source`, else just `source`.
func get_tracks_for_drag(source: Track) -> Array[Track]:
	var result: Array[Track] = []
	if source == null:
		return result
	var candidates: Array[Track] = [source]
	if selected_tracks.has(source):
		candidates = selected_tracks.duplicate()
	var selected_ids: Dictionary = {}
	for t in candidates:
		if t:
			selected_ids[t.id] = true
	for t in _get_visual_tracks():
		if not selected_ids.has(t.id):
			continue
		if _has_selected_ancestor(t, selected_ids):
			continue
		result.append(t)
	if result.is_empty():
		result.append(source)
	return result


## True if an ancestor of `track` is also in the drag set (it will travel with that parent).
func _has_selected_ancestor(track: Track, selected_ids: Dictionary) -> bool:
	if track == null or current_project == null:
		return false
	var walk_id := track.parent_track_id
	var visited: Dictionary = {}
	while walk_id >= 0:
		if selected_ids.has(walk_id):
			return true
		if visited.has(walk_id):
			break
		visited[walk_id] = true
		var parent := current_project.get_track_by_id(walk_id)
		if parent == null:
			break
		walk_id = parent.parent_track_id
	return false


## Dim every header that moves with `drag` until the drag ends.
func begin_track_drag(drag: TrackDrag) -> void:
	if drag == null or current_project == null:
		return
	var ids: Dictionary = {}
	for root in drag.tracks:
		ids[root.id] = true
	for child in get_children():
		if child is TrackItem and (child as TrackItem).track:
			var t := (child as TrackItem).track
			if ids.has(t.id) or _has_selected_ancestor(t, ids):
				(child as TrackItem).modulate.a = 0.5
	drag.drag_completed.connect(_on_track_drag_completed)
	logger.info("Track drag started: %d track(s)" % drag.tracks.size())


## Undim the dragged headers.
func _on_track_drag_completed(_drag: TrackDrag) -> void:
	for child in get_children():
		if child is TrackItem:
			(child as TrackItem).modulate.a = 1.0


## True when a track drag would move something at the pointer.
func can_drop_track_drag(drag: TrackDrag) -> bool:
	return TrackDropTarget.resolve(self, drag, get_global_mouse_position()).is_valid()


## Apply a track drag at the pointer through history.
func drop_track_drag(drag: TrackDrag) -> void:
	var target := TrackDropTarget.resolve(self, drag, get_global_mouse_position())
	DropIndicator.hide_indicator(_drop_indicator)
	if target.commit(drag):
		drag.did_commit = true
		logger.info("Track drop committed: %d track(s)" % drag.tracks.size())


## Update UI to match hierarchical track order.
func _update_visual_order() -> void:
	if not current_project:
		return
	
	# One ordering helper for both arranger columns, so headers and timeline rows can't drift.
	var rows := AutomationRowOrder.build(current_project)
	_fold_rows = rows
	_sync_lane_header_visibility(rows)
	_sync_track_item_visibility(rows)
	AutomationRowOrder.apply(self, rows, _node_for_row)
	AutomationRowOrder.apply_heights(current_project, rows, _node_for_row)

	logger.info("Updated visual order (%d rows)" % rows.size())


## Hide TrackItems of tracks folded away (not in `rows`); apply_heights() shows the rest.
func _sync_track_item_visibility(rows: Array) -> void:
	var shown: Dictionary = {}
	for row in rows:
		if row.get("lane") == null:
			shown[row["track"]] = true
	for child in get_children():
		if child is TrackItem and (child as TrackItem).track:
			child.visible = shown.has((child as TrackItem).track)


## Start (or reverse) the fold slide and rebuild rows; heights follow each animation step.
func _on_folder_expanded_changed(_expanded: bool, track: Track) -> void:
	if current_project == null:
		return
	var anim := TrackFoldAnimation.start(track)
	if anim and not anim.updated.is_connected(_on_fold_step):
		anim.updated.connect(_on_fold_step)
		anim.finished.connect(_update_visual_order)
	_update_visual_order()


## Resize rows for the current fold animation step.
func _on_fold_step() -> void:
	if current_project:
		AutomationRowOrder.apply_heights(current_project, _fold_rows, _node_for_row)


## The child Control representing `row`: a TrackItem for a track row, the lane's header for a
## lane row.
func _node_for_row(row: Dictionary) -> Node:
	var lane: AutomationLane = row.get("lane")
	if lane == null:
		return _find_track_item(row["track"])
	var header = _lane_headers.get(lane)
	return header if is_instance_valid(header) else null


## Show only the lane headers that AutomationRowOrder put in `rows`; hide the rest without
## freeing them, so re-checking a lane in the menu is instant and keeps its height.
func _sync_lane_header_visibility(rows: Array) -> void:
	var shown: Dictionary = {}
	for row in rows:
		var lane: AutomationLane = row.get("lane")
		if lane != null:
			shown[lane] = true
	for lane in _lane_headers:
		var header = _lane_headers[lane]
		if is_instance_valid(header):
			header.visible = shown.has(lane)


# ============================================================================
# AUTOMATION LANE ROWS
# ============================================================================

## Create the header rows for every lane on `track` that does not have one yet.
func _rebuild_lane_headers(track: Track) -> void:
	if track == null:
		return
	for lane in track.automation_lanes:
		_ensure_lane_header(track, lane)


func _ensure_lane_header(track: Track, lane: AutomationLane) -> AutomationLaneHeader:
	if lane == null:
		return null
	var existing = _lane_headers.get(lane)
	if is_instance_valid(existing):
		return existing

	var header := AutomationLaneHeader.new()
	add_child(header)
	header.bind_to_lane(lane, track, current_project)
	header.bypass_toggled.connect(_on_lane_bypass_toggled)
	header.delete_requested.connect(_on_lane_delete_requested.bind(track))
	# A lane menu checkbox changes which rows exist, so both columns re-order.
	lane.visibility_changed.connect(_on_lane_visibility_changed)
	_lane_headers[lane] = header
	return header


## Free every lane header belonging to `track`.
func _clear_lane_headers(track: Track) -> void:
	if track == null:
		return
	for lane in track.automation_lanes:
		_drop_lane_header(lane)


func _drop_lane_header(lane: AutomationLane) -> void:
	if lane == null:
		return
	if lane.visibility_changed.is_connected(_on_lane_visibility_changed):
		lane.visibility_changed.disconnect(_on_lane_visibility_changed)
	var header = _lane_headers.get(lane)
	if is_instance_valid(header):
		header.queue_free()
	_lane_headers.erase(lane)


func _on_automation_lane_added(lane: AutomationLane, track: Track) -> void:
	_ensure_lane_header(track, lane)
	# A lane the user just created should be visible without a second click.
	track.automation_expanded = true
	_update_visual_order()
	var item := _find_track_item(track)
	if item:
		item._update_automation_controls()


func _on_automation_lane_removed(lane: AutomationLane, track: Track) -> void:
	_drop_lane_header(lane)
	_update_visual_order()
	var item := _find_track_item(track)
	if item:
		item._update_automation_controls()


func _on_automation_expanded_changed(_expanded: bool, _track: Track) -> void:
	_update_visual_order()


func _on_lane_visibility_changed(_visible: bool) -> void:
	_update_visual_order()


## Disclosure arrow on a track header.
func _on_automation_disclosure_toggled(track: Track, expanded: bool) -> void:
	if track:
		track.automation_expanded = expanded


## Automation button on a track header: open the lane menu (REQ-014).
func _on_automation_menu_requested(track: Track, mouse_position: Vector2) -> void:
	if track == null:
		return
	if _lane_menu == null:
		_lane_menu = AutomationLaneMenu.new()
		add_child(_lane_menu)
		_lane_menu.add_lane_requested.connect(_on_add_lane_requested)
	_lane_menu.open_for(track, mouse_position)


## `+ Add new` in the lane menu: pick a parameter, then create the lane (REQ-015).
func _on_add_lane_requested(track: Track) -> void:
	if track == null:
		return
	if _parameter_picker == null:
		_parameter_picker = AutomationParameterPicker.new()
		add_child(_parameter_picker)
		_parameter_picker.parameter_chosen.connect(_on_automation_parameter_chosen)
	_parameter_picker.open_for(track, get_global_mouse_position())


## Build the lane and record it as one undoable step. It starts with a single point holding the
## parameter's current value, so creating a lane never jumps what you hear (REQ-004).
func _on_automation_parameter_chosen(track: Track, target: AutomationTarget) -> void:
	if track == null or target == null:
		return
	var lane := AutomationLane.new(_unique_lane_id(track), target)
	lane.height = Settings.get_value("appearance/automation_lane_height")
	lane.color = Utils.display_color(track.color)
	var seed_value: float = target.current_normalized_value(track.get_linked_channel())
	AutomationActions.create_lane(track, lane)
	AutomationActions.add_point(lane, 0, seed_value)


## A lane id unique within `track`. Ids are per-track because that is the OSC addressing scope.
func _unique_lane_id(track: Track) -> String:
	var used: Dictionary = {}
	for lane in track.automation_lanes:
		used[lane.id] = true
	var n := track.automation_lanes.size()
	while used.has("lane%d" % n):
		n += 1
	return "lane%d" % n


func _on_lane_bypass_toggled(lane: AutomationLane, bypassed: bool) -> void:
	HistoryUtil.execute_property(
		"Bypass Lane" if bypassed else "Enable Lane",
		lane, "set_bypassed", not bypassed, bypassed
	)


func _on_lane_delete_requested(lane: AutomationLane, track: Track) -> void:
	AutomationActions.delete_lane(track, lane)


## Find the TrackItem UI element for a given track.
func _find_track_item(track: Track) -> TrackItem:
	for child in get_children():
		if child is TrackItem:
			var item = child as TrackItem
			if item.track == track:
				return item
	return null


## Scroll the arranger list so a track header stays on screen during rename-tab.
func _ensure_track_item_visible(item: TrackItem) -> void:
	if item == null:
		return
	var node := get_parent()
	while node:
		if node is ScrollContainer:
			(node as ScrollContainer).ensure_control_visible(item)
			return
		node = node.get_parent()
