# TrackList.gd
# Container for TrackItem UI elements
# Listens to Editor signals and creates/removes TrackItems accordingly

class_name TrackList extends VBoxContainer

## Owns arranger track-header selection: multi-select, active track, and visual updates.

# Scene to instantiate for each track
const track_item_scene: PackedScene = preload("res://arranger/tracklist/TrackItem.tscn")

# context menu to show when right-clicking empty area
@onready var context_menu: TrackListContextMenu = $TrackListContextMenu

# context menu when right-clicking a trackitem
@onready var track_item_context_menu: TrackItemContextMenu = $TrackItemContextMenu

# Track items indexed by track index
var track_items: Array[TrackItem] = []

# Current project reference
var current_project: Project = null

# Header selection: last selected track is active.
var selected_tracks: Array[Track] = []
var active_track: Track = null
var _selection_anchor: Track = null
var _is_rebuilding: bool = false

## Live track-header reorder (null when no TrackDrag is in progress).
var _reorder_drag: TrackDrag = null

## Pixels per folder nesting level; matches TrackItem indent.
@export var folder_indent_pixels: int = 12

signal selection_changed(tracks: Array[Track], active: Track)

func _ready():
	# remove any nodes
	for child in get_children():
		if child is TrackItem:
			child.free()
	
	# Ensure TrackList fills parent so empty areas can receive drops
	size_flags_vertical = Control.SIZE_FILL | Control.SIZE_EXPAND
	
	# Connect to Editor signals for project lifecycle
	if Sonara and Sonara.editor:
		Sonara.editor.project_activated.connect(_on_project_activated)
		Sonara.editor.project_closed.connect(_on_project_closed)

	# Enable drag and drop
	set_drag_forwarding(Callable(self, "_get_drag_data"), Callable(self, "_can_drop_data"), Callable(self, "_drop_data"))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		context_menu.popup(Rect2(get_global_mouse_position() - Vector2.ONE * 10, Vector2.ZERO))
		# force grab focus to the context menu
		context_menu.grab_focus()
		accept_event()


## Finish or revert a track reorder when Godot ends the GUI drag.
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_on_track_drag_ended()


## Cancel live reorder via Escape so the layout snapshot can be restored.
func _input(event: InputEvent) -> void:
	if _reorder_drag == null:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().gui_cancel_drag()
		accept_event()


# ============================================================================
# EDITOR/PROJECT SIGNAL CALLBACKS
# ============================================================================
func _on_project_activated(project: Project) -> void:
	"""Called when a project is activated - bind to its signals and sync UI."""
	# Clean up old connections if any
	if current_project:
		_unbind_from_project()

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

	print("[TrackList] Project activated: ", project.project_name)


func _on_project_closed() -> void:
	"""Clear all track items when project closes."""
	if current_project:
		_unbind_from_project()

	_clear_selection(false)
	_clear_all_track_items()
	_end_track_reorder()

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

	# Store reference
	if index >= track_items.size():
		track_items.resize(index + 1)
	track_items[index] = track_item

	print("[TrackList] Track added: ", track.name, " at index ", index, " with order ", track.order)

	if not _is_rebuilding:
		_update_visual_order()
		_select_track(track, false, false)


func _on_track_removed(track: Track) -> void:
	"""Remove the TrackItem UI element for the removed track."""
	var track_item = _find_track_item(track)
	if not track_item:
		push_warning("[TrackList] Track item not found for removed track: %s" % track.name)
		return
	
	# Disconnect from track signals
	if track.order_changed.is_connected(_on_track_layout_changed):
		track.order_changed.disconnect(_on_track_layout_changed)
	if track.parent_changed.is_connected(_on_track_layout_changed):
		track.parent_changed.disconnect(_on_track_layout_changed)

	_remove_track_from_selection(track)
	
	# Remove from track_items array
	var index = track_items.find(track_item)
	if index >= 0:
		track_items.remove_at(index)
	
	# Remove from scene tree and free
	track_item.queue_free()
	
	print("[TrackList] Track item removed for: ", track.name)


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
	
	print("[TrackList] Track item right-clicked: ", track.name)

	if not selected_tracks.has(track):
		_select_track(track, false, false)
	
	# Bind the context menu to the track
	track_item_context_menu.bind(track, current_project)
	
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
			track_item.queue_free()
	
	track_items.clear()
	

# ============================================================================
# TRACK SELECTION
# ============================================================================

## Apply header selection. Last selected track becomes active.
func _select_track(track: Track, additive: bool, range_select: bool, apply_record_arm: bool = true) -> void:
	if track == null:
		return

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
			if item.track:
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


## Accept live track reordering or device/SFZ asset drops.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not current_project:
		return false

	if data is TrackDrag:
		preview_track_drop(get_global_mouse_position())
		return true

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
		commit_track_drop()
		return
	
	# Handle array of assets
	if data is Array:
		print("[TrackList] Dropping %d assets" % data.size())
		for asset in data:
			if asset is Asset:
				_handle_single_asset_drop(asset)
		return
	
	# Handle single asset
	if data is Asset:
		_handle_single_asset_drop(data)


func _handle_single_asset_drop(asset: Asset) -> void:
	"""Handle dropping a single asset."""
	# Handle SFZ asset drops
	if asset.type == Asset.TYPE.SFZ:
		print("[TrackList] SFZ dropped: ", asset.name, " (", asset.path, ")")
		_create_sfz_instrument_track(asset.path, asset.name)
		return
	
	# Handle device asset drops
	if asset.type == Asset.TYPE.Device:
		print("[TrackList] Device dropped: ", asset.name, " (", asset.path, ")")
		
		# Get the device metadata
		var device = AssetService.get_device(asset.path)
		if not device:
			push_error("[TrackList] Failed to get device: ", asset.path)
			return
		
		# Instruments and MIDI containers (Layer/Chain) get their own track.
		if device.creates_instrument_track():
			_create_instrument_track_with_device(device)
		elif device.category == Device.DeviceCategory.Effect or device.category == Device.DeviceCategory.Utility:
			_add_effect_to_track(device)
		else:
			push_warning("[TrackList] No drop handler for %s (%s)" % [device.name, device.get_category_string()])


func _create_instrument_track_with_device(device: Device) -> void:
	"""Create a new instrument track and add the device to its channel."""
	print("[TrackList] Creating instrument track with device: ", device.name)

	# Create new instrument track + channel pair
	var _track_cmd := TrackCreateCommand.new(current_project, "instrument", device.name)
	HistoryUtil.execute(_track_cmd)
	var result = {"track": _track_cmd.track, "channel": _track_cmd.channel}
	if not result:
		push_error("[TrackList] Failed to create instrument track")
		return

	var track = result["track"] as Track
	var channel = result["channel"] as Channel

	if not track or not channel:
		push_error("[TrackList] Invalid track or channel returned")
		return

	print("[TrackList] Created track: ", track.name, " (id=", track.id, ", channel_id=", track.default_channel_id, ")")
	print("[TrackList] Created channel: ", channel.name, " (id=", channel.id, ")")

	# Create device instance and add to channel
	# Channel.add_device() handles OSC sync and emits device_added signal
	var device_instance = DeviceInstance.new(device, channel.id, 0)
	channel.add_device(device_instance, -1)


func _add_effect_to_track(device: Device) -> void:
	"""Add effect device to the first track's channel (or create a new track if none exist)."""
	print("[TrackList] Adding effect device: ", device.name)

	var target_channel: Channel = null
	var target_track: Track = active_track
	if target_track == null and current_project.tracks.size() > 0:
		target_track = current_project.tracks[0] as Track

	if target_track:
		for ch in current_project.channels:
			if ch.id == target_track.default_channel_id:
				target_channel = ch
				break

	# If no channel found, create a new bus channel for the effect
	if not target_channel:
		print("[TrackList] No target channel found, creating bus channel")
		target_channel = current_project.create_bus_channel(device.name)
		if not target_channel:
			push_error("[TrackList] Failed to create bus channel")
			return

	# Create device instance and add to channel
	# Channel.add_device() handles OSC sync and emits device_added signal
	var device_instance = DeviceInstance.new(device, target_channel.id, target_channel.get_device_count())
	target_channel.add_device(device_instance, -1)


func _create_sfz_instrument_track(sfz_path: String, sfz_name: String) -> void:
	"""Create a new instrument track with sfizz device and load the SFZ file."""
	print("[TrackList] Creating SFZ instrument track: ", sfz_name)
	
	# Get the sfizz device from AssetService
	var sfizz_device = AssetService.get_device("sonara.builtin.sfizz")
	if not sfizz_device:
		push_error("[TrackList] Failed to get sfizz device")
		return
	
	# Create new instrument track + channel pair
	var _track_cmd := TrackCreateCommand.new(current_project, "instrument", sfz_name)
	HistoryUtil.execute(_track_cmd)
	var result = {"track": _track_cmd.track, "channel": _track_cmd.channel}
	if not result:
		push_error("[TrackList] Failed to create instrument track")
		return
	
	var track = result["track"] as Track
	var channel = result["channel"] as Channel
	
	if not track or not channel:
		push_error("[TrackList] Invalid track or channel returned")
		return
	
	print("[TrackList] Created track: ", track.name, " (id=", track.id, ", channel_id=", track.default_channel_id, ")")
	print("[TrackList] Created channel: ", channel.name, " (id=", channel.id, ")")
	
	# Create sfizz device instance and add to channel
	var device_instance = DeviceInstance.new(sfizz_device, channel.id, 0)
	channel.add_device(device_instance, -1)
	
	# Load the SFZ file into the device
	# Give the engine a moment to create the device before loading the file
	await get_tree().create_timer(0.1).timeout
	device_instance.load_file(sfz_path)


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


## True if an ancestor of `track` is also in the drag set (it will travel with that folder).
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


## Start a live reorder: snapshot layout and dim every dragged header.
func begin_track_reorder(drag: TrackDrag) -> void:
	if drag == null or drag.track == null or current_project == null:
		return
	_reorder_drag = drag
	_reorder_drag.before_layout = TrackReorderCommand.capture_layout(current_project)
	_reorder_drag.did_commit = false
	_set_dragged_items_dimmed(true)
	print("[TrackList] Live reorder started: %d track(s)" % _dragged_roots().size())


## Move the dragged tracks under the pointer so headers and timeline stay in sync.
func preview_track_drop(mouse_global: Vector2) -> void:
	if _reorder_drag == null or current_project == null:
		return
	var placement := _compute_drop_placement(mouse_global)
	if placement.is_empty():
		return
	var parent_id := int(placement["parent_id"])
	var after_sibling: Track = placement.get("after_sibling")
	var after_anchor := after_sibling
	var roots := _dragged_roots()
	for root in roots:
		if current_project.track_is_in_subtree(parent_id, root):
			return
	current_project.begin_track_layout_batch()
	var any_moved := false
	for root in roots:
		if current_project.place_track(root, parent_id, after_sibling):
			any_moved = true
		after_sibling = root
	current_project.end_track_layout_batch()
	if any_moved:
		print(
			"[TrackList] Live place %d track(s) parent=%s after=%s"
			% [
				roots.size(),
				str(parent_id),
				after_anchor.name if after_anchor else "first",
			]
		)


## Commit the live layout to history, or no-op if nothing changed.
func commit_track_drop() -> void:
	if _reorder_drag == null or current_project == null:
		return
	_reorder_drag.did_commit = true
	var after_layout := TrackReorderCommand.capture_layout(current_project)
	if not TrackReorderCommand.layouts_equal(_reorder_drag.before_layout, after_layout):
		HistoryUtil.record(
			TrackReorderCommand.new(current_project, _reorder_drag.before_layout, after_layout)
		)
		print("[TrackList] Reorder committed: %d track(s)" % _dragged_roots().size())
	_end_track_reorder()


## Restore the pre-drag layout when ESC or an unsuccessful drop cancels.
func _on_track_drag_ended() -> void:
	if _reorder_drag == null:
		return
	if _reorder_drag.did_commit:
		_end_track_reorder()
		return
	print("[TrackList] Reorder cancelled, restoring layout")
	current_project.apply_track_layout(_reorder_drag.before_layout)
	_end_track_reorder()


## Clear drag visuals and session state.
func _end_track_reorder() -> void:
	_set_dragged_items_dimmed(false)
	_reorder_drag = null


## Dim or restore every header in the dragged subtrees.
func _set_dragged_items_dimmed(dimmed: bool) -> void:
	if _reorder_drag == null:
		return
	var ids := _all_dragged_subtree_ids()
	var alpha := 0.7 if dimmed else 1.0
	for child in get_children():
		if child is TrackItem:
			var item := child as TrackItem
			if item.track and ids.has(item.track.id):
				item.modulate.a = alpha


## Movable roots for the current drag (folder children travel with their folder).
func _dragged_roots() -> Array[Track]:
	if _reorder_drag == null:
		return []
	if not _reorder_drag.tracks.is_empty():
		return _reorder_drag.tracks
	if _reorder_drag.track:
		return [_reorder_drag.track]
	return []


## Compute parent + after-sibling from pointer Y (order) and X (folder indent).
func _compute_drop_placement(mouse_global: Vector2) -> Dictionary:
	if _reorder_drag == null or current_project == null:
		return {}
	var skip := _dragged_root_ids()
	var subtree := _all_dragged_subtree_ids()
	var remaining: Array[TrackItem] = []
	for child in get_children():
		if child is TrackItem:
			var item := child as TrackItem
			if item.track and not subtree.has(item.track.id):
				remaining.append(item)
	if remaining.is_empty():
		return {}

	var hovered: TrackItem = null
	var insert_before := true
	for item in remaining:
		var rect := item.get_global_rect()
		if mouse_global.y < rect.position.y + rect.size.y * 0.5:
			hovered = item
			insert_before = true
			break
		if mouse_global.y < rect.end.y:
			hovered = item
			insert_before = false
			break
	if hovered == null:
		hovered = remaining.back()
		insert_before = false

	var local_x := mouse_global.x - get_global_rect().position.x
	if insert_before:
		return _placement_before(hovered.track, _desired_level_before(hovered.track, local_x), skip)
	var nest_into_folder := (
		hovered.track.type == Track.TrackType.FOLDER
		and mouse_global.x >= hovered.get_global_rect().get_center().x
	)
	return _placement_after(
		hovered.track,
		_desired_level_after(hovered.track, local_x, nest_into_folder),
		skip
	)


## Nesting level when inserting after `item`. Right half of a folder nests; a left gutter un-nests.
func _desired_level_after(item: Track, local_x: float, nest_into_folder: bool) -> int:
	var item_level := item.get_nesting_level(current_project)
	if nest_into_folder and item.type == Track.TrackType.FOLDER:
		return item_level + 1
	return _desired_level_from_x(item_level, local_x)


## Nesting level when inserting before `item`: same as `item`, or one level shallower in the left gutter.
func _desired_level_before(item: Track, local_x: float) -> int:
	return _desired_level_from_x(item.get_nesting_level(current_project), local_x)


## Keep `item_level` unless the pointer is in the left gutter, which pulls out one folder level.
func _desired_level_from_x(item_level: int, local_x: float) -> int:
	if item_level <= 0:
		return 0
	var item_indent := float(item_level * folder_indent_pixels)
	if local_x < item_indent + 20.0:
		return item_level - 1
	return item_level


## Insert before `item`, un-nesting when the pointer is left of `item`'s indent.
func _placement_before(item: Track, desired_level: int, skip: Dictionary) -> Dictionary:
	var item_level := item.get_nesting_level(current_project)
	var level := clampi(desired_level, 0, item_level)
	var cursor := item
	while cursor:
		var cursor_level := cursor.get_nesting_level(current_project)
		if cursor_level <= level:
			return {
				"parent_id": cursor.parent_track_id,
				"after_sibling": _previous_sibling(cursor, skip),
			}
		if cursor.parent_track_id < 0:
			break
		cursor = current_project.get_track_by_id(cursor.parent_track_id)
	return {
		"parent_id": item.parent_track_id,
		"after_sibling": _previous_sibling(item, skip),
	}


## Insert after `item`; indenting into a folder makes the dragged tracks its first children.
func _placement_after(item: Track, desired_level: int, skip: Dictionary) -> Dictionary:
	var item_level := item.get_nesting_level(current_project)
	var max_level := item_level + (1 if item.type == Track.TrackType.FOLDER else 0)
	var level := clampi(desired_level, 0, max_level)
	if item.type == Track.TrackType.FOLDER and level > item_level:
		var nest_blocked := false
		for root in _dragged_roots():
			if current_project.track_is_in_subtree(item.id, root):
				nest_blocked = true
				break
		if not nest_blocked:
			return {"parent_id": item.id, "after_sibling": null}

	var cursor := item
	while cursor:
		var cursor_level := cursor.get_nesting_level(current_project)
		if cursor_level <= level:
			var after: Track = cursor
			if skip.has(cursor.id):
				after = _previous_sibling(cursor, skip)
			return {
				"parent_id": cursor.parent_track_id,
				"after_sibling": after,
			}
		if cursor.parent_track_id < 0:
			return {"parent_id": -1, "after_sibling": cursor}
		cursor = current_project.get_track_by_id(cursor.parent_track_id)
	return {"parent_id": item.parent_track_id, "after_sibling": item}


## Sibling directly above `track` in the same folder, skipping dragged roots.
func _previous_sibling(track: Track, skip: Dictionary) -> Track:
	var siblings: Array[Track] = []
	for t in current_project.tracks:
		if t.parent_track_id == track.parent_track_id:
			siblings.append(t)
	siblings.sort_custom(func(a, b): return a.order < b.order)
	var previous: Track = null
	for sibling in siblings:
		if sibling == track:
			break
		if not skip.has(sibling.id):
			previous = sibling
	return previous


## IDs of movable drag roots (not their descendants).
func _dragged_root_ids() -> Dictionary:
	var ids: Dictionary = {}
	for root in _dragged_roots():
		ids[root.id] = true
	return ids


## Every track that moves with the current drag, including folder descendants.
func _all_dragged_subtree_ids() -> Dictionary:
	var ids: Dictionary = {}
	for root in _dragged_roots():
		_collect_subtree_ids(root, ids)
	return ids


## Recursively record `track` and its folder children into `ids`.
func _collect_subtree_ids(track: Track, ids: Dictionary) -> void:
	if track == null:
		return
	ids[track.id] = true
	if track.type != Track.TrackType.FOLDER:
		return
	for child in current_project.get_track_children(track):
		_collect_subtree_ids(child, ids)


## Update UI to match hierarchical track order.
func _update_visual_order() -> void:
	if not current_project:
		return
	
	# Get flat visual list from hierarchy
	var visual_tracks = current_project.get_visual_track_list()
	
	# Reorder UI elements to match
	for i in range(visual_tracks.size()):
		var track = visual_tracks[i]
		var track_item = _find_track_item(track)
		if track_item:
			move_child(track_item, i)

	if _reorder_drag == null:
		print("[TrackList] Updated visual order (%d tracks)" % visual_tracks.size())


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
