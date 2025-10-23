# TrackList.gd
# Container for TrackItem UI elements
# Listens to Editor signals and creates/removes TrackItems accordingly

class_name TrackList extends VBoxContainer

# Scene to instantiate for each track
const track_item_scene: PackedScene = preload("res://arranger/tracklist/TrackItem.tscn")

# Track items indexed by track index
var track_items: Array[TrackItem] = []

# Current project reference
var current_project: Project = null

func _ready():
	# remove any nodes
	for child in get_children():
		child.free()
	
	# Ensure TrackList fills parent so empty areas can receive drops
	size_flags_vertical = Control.SIZE_FILL | Control.SIZE_EXPAND
	
	# Connect to Editor signals for project lifecycle
	if Sonara and Sonara.editor:
		Sonara.editor.project_activated.connect(_on_project_activated)
		Sonara.editor.project_closed.connect(_on_project_closed)

	# Enable drag and drop
	set_drag_forwarding(Callable(self, "_get_drag_data"), Callable(self, "_can_drop_data"), Callable(self, "_drop_data"))

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

	# Sync UI with existing tracks
	for i in range(current_project.tracks.size()):
		_on_track_added(current_project.tracks[i])

	print("[TrackList] Project activated: ", project.project_name)


func _on_project_closed() -> void:
	"""Clear all track items when project closes."""
	if current_project:
		_unbind_from_project()
	current_project = null
	_clear_all_tracks()


func _unbind_from_project() -> void:
	"""Disconnect from current project signals."""
	if current_project and current_project.track_added.is_connected(_on_track_added):
		current_project.track_added.disconnect(_on_track_added)


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

	# Find correct position based on order property
	var insert_position = _find_insert_position(track.order)

	# Add to container at correct position
	add_child(track_item)
	move_child(track_item, insert_position)

	# Bind to track data and pass project reference for channel lookup
	track_item.bind_to_track(track, index, current_project)
	
	# Connect to track signals for reordering
	track.order_changed.connect(_on_track_order_changed)

	# Store reference
	if index >= track_items.size():
		track_items.resize(index + 1)
	track_items[index] = track_item

	print("[TrackList] Track added: ", track.name, " at index ", index, " with order ", track.order)


func _on_track_order_changed(_new_order: int) -> void:
	"""Handle track order changes to update visual order."""
	if not current_project:
		return
	
	print("[TrackList] Track order changed, updating visual order")
	_update_visual_order()


# ============================================================================
# INTERNAL HELPERS
# ============================================================================

func _clear_all_tracks() -> void:
	"""Remove all track items."""
	for track_item in track_items:
		if track_item:
			track_item.queue_free()
	track_items.clear()
	
	# Also clear any remaining children
	for child in get_children():
		child.queue_free()
	
	print("[TrackList] All tracks cleared")

func _find_insert_position(order: int) -> int:
	"""Find the correct position to insert a track based on its order value."""
	var insert_pos = 0
	for child in get_children():
		if child is TrackItem:
			var child_track = child as TrackItem
			if child_track.track and child_track.track.order <= order:
				insert_pos += 1
			else:
				break
	return insert_pos


# ============================================================================
# DRAG AND DROP
# ============================================================================

func _get_drag_data(at_position: Vector2) -> Variant:
	"""Return drag data from this node (not used for tracklist, but required by set_drag_forwarding)."""
	return null


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	"""Check if we can drop data (device assets) on the tracklist."""
	if not current_project:
		return false

	# Check if data is a device asset
	if data is Asset and data.type == Asset.TYPE.Device:
		return true

	return false


func _drop_data(at_position: Vector2, data: Variant) -> void:
	"""Handle dropping a device on the tracklist."""
	if not data is Asset or not current_project:
		return

	var asset = data as Asset
	if asset.type != Asset.TYPE.Device:
		return

	print("[TrackList] Device dropped: ", asset.name, " (", asset.path, ")")

	# Get the device metadata
	var device = AssetService.get_device(asset.path)
	if not device:
		push_error("[TrackList] Failed to get device: ", asset.path)
		return

	# Create instrument track + channel pair
	if device.category == Device.DeviceCategory.Instrument:
		_create_instrument_track_with_device(device)
	elif device.category == Device.DeviceCategory.Effect:
		# For effects, add to existing selected track or create new track
		_add_effect_to_track(device)


func _create_instrument_track_with_device(device: Device) -> void:
	"""Create a new instrument track and add the device to its channel."""
	print("[TrackList] Creating instrument track with device: ", device.name)

	# Create new instrument track + channel pair
	var result = current_project.create_instrument_track(device.name)
	if not result:
		push_error("[TrackList] Failed to create instrument track")
		return

	var track = result["track"] as Track
	var channel = result["channel"] as Channel

	print("[TrackList] Created track: ", track.name, " (id=", track.id, ")")
	print("[TrackList] Created channel: ", channel.name, " (id=", channel.id, ")")

	# Create device instance and add to channel
	# Channel.add_device() handles OSC sync and emits device_added signal
	var device_instance = DeviceInstance.new(device, channel.id, 0)
	channel.add_device(device_instance, -1)


func _add_effect_to_track(device: Device) -> void:
	"""Add effect device to the first track's channel (or create a new track if none exist)."""
	print("[TrackList] Adding effect device: ", device.name)

	var target_channel: Channel = null

	# Try to find first track's channel
	if current_project.tracks.size() > 0:
		var first_track = current_project.tracks[0] as Track
		for ch in current_project.channels:
			if ch.id == first_track.default_channel_id:
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


# ============================================================================
# TRACK REORDERING
# ============================================================================

func insert_track_after(track_to_move: Track, target_track: Track) -> void:
	"""Reorder tracks by inserting track_to_move after target_track as a sibling."""
	if not current_project or not track_to_move or not target_track:
		return
	
	# Can't insert after self
	if track_to_move == target_track:
		return
	
	print("[TrackList] Reordering: '%s' after '%s'" % [track_to_move.name, target_track.name])
	
	# Track becomes a sibling of target (same parent)
	var new_parent_id = target_track.parent_track_id
	var old_parent_id = track_to_move.parent_track_id
	
	# Remove from old parent's child list
	if old_parent_id >= 0:
		var old_parent = current_project.get_track_by_id(old_parent_id)
		if old_parent:
			old_parent.child_track_ids.erase(track_to_move.id)
	
	# Update parent
	track_to_move.parent_track_id = new_parent_id
	
	# Add to new parent's child list if it's a folder
	if new_parent_id >= 0:
		var new_parent = current_project.get_track_by_id(new_parent_id)
		if new_parent and new_parent.type == Track.TrackType.FOLDER:
			if not new_parent.child_track_ids.has(track_to_move.id):
				new_parent.child_track_ids.append(track_to_move.id)
	
	# Build the new sibling order
	# Get current siblings (excluding track_to_move since it was already removed/added)
	var all_siblings: Array[Track] = []
	for t in current_project.tracks:
		if t.parent_track_id == new_parent_id:
			all_siblings.append(t)
	
	# Sort by current order
	all_siblings.sort_custom(func(a, b): return a.order < b.order)
	
	# Find target and rebuild order with track_to_move inserted after it
	var new_sibling_order: Array[Track] = []
	var inserted = false
	for sibling in all_siblings:
		if sibling == track_to_move:
			continue  # Skip, we'll insert it explicitly
		new_sibling_order.append(sibling)
		if sibling == target_track:
			new_sibling_order.append(track_to_move)
			inserted = true
	
	# If target not found (shouldn't happen), append at end
	if not inserted:
		new_sibling_order.append(track_to_move)
	
	# Apply new sequential order
	for i in range(new_sibling_order.size()):
		new_sibling_order[i].order = i
	
	# Also renumber old parent's siblings if changed parents
	if old_parent_id != new_parent_id:
		current_project._renumber_siblings(old_parent_id)
	
	# Update UI to reflect new visual order
	_update_visual_order()
	
	print("[TrackList] Reordered: '%s' now has parent %d and order %d" % [track_to_move.name, track_to_move.parent_track_id, track_to_move.order])


func _update_visual_order() -> void:
	"""Update UI to match hierarchical track order."""
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
	
	print("[TrackList] Updated visual order (%d tracks)" % visual_tracks.size())


func _find_track_item(track: Track) -> TrackItem:
	"""Find the TrackItem UI element for a given track."""
	for child in get_children():
		if child is TrackItem:
			var item = child as TrackItem
			if item.track == track:
				return item
	return null
