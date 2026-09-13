# Undoable folder↔bus pairing (group tracks) plus descendant mixer routing.
class_name TrackLinkBusCommand extends Command

const CREATE_NEW := -2
const UNLINK := -1

## Project that owns the folder and buses.
var project: Project = null

## Folder/group track being linked.
var track: Track = null

## Target bus, or null when unlinking. Created on first do() when create_new is true.
var bus: Channel = null

## When true, first do() creates a bus named/colored like the track.
var create_new: bool = false

var _old_channel_id: int = -1
var _old_color_by_channel: bool = true
var _old_name_by_channel: bool = true
var _old_output_routes: Dictionary = {}
var _snapshotted: bool = false


## Link `p_track` to `p_bus`, unlink when bus is null, or create a bus when create_new.
func _init(
	p_project: Project = null,
	p_track: Track = null,
	p_bus: Channel = null,
	p_create_new: bool = false
) -> void:
	project = p_project
	track = p_track
	bus = p_bus
	create_new = p_create_new
	if create_new:
		name = "Link Track to New Bus"
	elif p_bus:
		name = "Link Track to Bus"
	else:
		name = "Unlink Track Bus"


## Apply the new bus pairing and child routing.
func do() -> void:
	if project == null or track == null:
		return
	if not _snapshotted:
		_snapshot()
		_snapshotted = true
	if create_new:
		if bus == null:
			bus = project.create_and_link_folder_bus(track)
		else:
			if project.get_channel_by_id(bus.id) == null:
				project.add_channel(bus)
			project.link_folder_to_bus(track, bus)
		return
	if bus:
		project.link_folder_to_bus(track, bus)
	else:
		project.unlink_folder_from_bus(track)


## Restore previous pairing and mixer output routes.
func undo() -> void:
	if project == null or track == null:
		return
	if _old_channel_id >= 0:
		var old_bus := project.get_channel_by_id(_old_channel_id)
		if old_bus:
			project.link_folder_to_bus(track, old_bus)
		else:
			project.unlink_folder_from_bus(track)
	else:
		project.unlink_folder_from_bus(track)
	if create_new and bus:
		project.remove_channel(bus.id)
	_restore_output_routes()
	track.color_by_channel = _old_color_by_channel
	track.name_by_channel = _old_name_by_channel


## Capture pairing flags and every mixer output in this subtree.
func _snapshot() -> void:
	_old_channel_id = track.default_channel_id
	_old_color_by_channel = track.color_by_channel
	_old_name_by_channel = track.name_by_channel
	_old_output_routes.clear()
	_snapshot_track_route(track)
	if track.type == Track.TrackType.FOLDER:
		var stack: Array[Track] = project.get_track_children(track)
		while not stack.is_empty():
			var child: Track = stack.pop_back()
			_snapshot_track_route(child)
			if child.type == Track.TrackType.FOLDER:
				stack.append_array(project.get_track_children(child))


## Record one track's mixer output if it has a channel.
func _snapshot_track_route(t: Track) -> void:
	var ch := project.get_track_mixer_channel(t)
	if ch:
		_old_output_routes[ch.id] = ch.output_channel_id


## Re-apply snapshotted mixer outputs (skips channels that no longer exist).
func _restore_output_routes() -> void:
	for channel_id in _old_output_routes:
		var ch := project.get_channel_by_id(int(channel_id))
		if ch == null:
			continue
		var target_id: int = _old_output_routes[channel_id]
		if ch.output_channel_id != target_id:
			ch.set_route(target_id)
