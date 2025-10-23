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

	# Store reference
	if index >= track_items.size():
		track_items.resize(index + 1)
	track_items[index] = track_item

	print("[TrackList] Track added: ", track.name, " at index ", index, " with order ", track.order)

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
