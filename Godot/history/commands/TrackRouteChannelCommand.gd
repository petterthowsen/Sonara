# Undoable routing of a track to a mixer channel, including "New Channel" and unrouting.
class_name TrackRouteChannelCommand extends Command

const CREATE_NEW := -2
const UNROUTE := -1

## Project that owns the track and channels.
var project: Project = null

## Track being rerouted.
var track: Track = null

## Target channel, or null when unrouting. Created on first do() when create_new is true.
var channel: Channel = null

## When true, first do() creates a channel named/colored like the track.
var create_new: bool = false

var _old_channel_id: int = -1
var _old_color_by_channel: bool = true
var _old_name_by_channel: bool = true
var _old_color: Color = Color.WHITE
var _old_name: String = ""
var _snapshotted: bool = false


## Route `p_track` to `p_channel`, unroute when it is null, or create a channel when create_new.
func _init(
	p_project: Project = null,
	p_track: Track = null,
	p_channel: Channel = null,
	p_create_new: bool = false
) -> void:
	project = p_project
	track = p_track
	channel = p_channel
	create_new = p_create_new
	if create_new:
		name = "Route Track to New Channel"
	elif p_channel:
		name = "Route Track to Channel"
	else:
		name = "Unroute Track"


## Apply the new routing.
func do() -> void:
	if project == null or track == null:
		return
	if not _snapshotted:
		_snapshot()
		_snapshotted = true
	if create_new:
		if channel == null:
			channel = project.create_and_link_track_channel(track)
		else:
			# Redo: the channel object survives in this command, so reuse its identity.
			if project.get_channel_by_id(channel.id) == null:
				project.add_channel(channel, track)
			project.route_track_to_channel(track, channel)
		return
	project.route_track_to_channel(track, channel)


## Restore the previous routing and the track's own name/color.
func undo() -> void:
	if project == null or track == null:
		return
	var old_channel := project.get_channel_by_id(_old_channel_id) if _old_channel_id >= 0 else null
	project.route_track_to_channel(track, old_channel)
	if create_new and channel:
		# Unregister first: remove_channel reroutes whatever is still on the strip to Master.
		channel.unregister_track(track)
		project.remove_channel(channel.id)
	track.color_by_channel = _old_color_by_channel
	track.name_by_channel = _old_name_by_channel
	# route_track_to_channel may have pulled a strip's identity onto the track; put it back.
	if not _old_name_by_channel and track.name != _old_name:
		track.name = _old_name
	if not _old_color_by_channel:
		track.set_color(_old_color)


## Capture the routing and identity this command is about to overwrite.
func _snapshot() -> void:
	_old_channel_id = track.default_channel_id
	_old_color_by_channel = track.color_by_channel
	_old_name_by_channel = track.name_by_channel
	_old_color = track.get_color()
	_old_name = track.name
