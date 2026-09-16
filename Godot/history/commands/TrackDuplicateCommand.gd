# TrackDuplicateCommand.gd
# Undoable duplicate of a clip track, placed right after the original. Clips (same pooled clips,
# fresh instance ids) and automation lanes are copied. With `with_channel`, the mixer channel is
# copied too (devices with fresh ids, sends, output route and group nesting); otherwise the copy
# plays through the original's channel. Keeps Track + Channel identity for redo.
class_name TrackDuplicateCommand extends Command

## Project that owns the tracks.
var project: Project = null

## Track being copied.
var source: Track = null

## When true, the copy gets its own copy of the source's channel.
var with_channel: bool = false

## The copy, created on the first do().
var track: Track = null

## The copied channel (with_channel only), created on the first do().
var channel: Channel = null

var _before_layout: Dictionary = {}
var _after_layout: Dictionary = {}


## Duplicate `p_source`, optionally with its channel.
func _init(p_project: Project = null, p_source: Track = null, p_with_channel: bool = false) -> void:
	project = p_project
	source = p_source
	with_channel = p_with_channel
	name = "Duplicate Track and Channel" if p_with_channel else "Duplicate Track"


## True when `t` can be duplicated (clip tracks; folders and groups carry children instead).
static func can_duplicate(t: Track) -> bool:
	return t != null and t.has_clips()


## Create the copy (first run) or re-add it (redo).
func do() -> void:
	if project == null or not can_duplicate(source):
		return
	if track == null:
		_before_layout = TrackReorderCommand.capture_layout(project)
		_create()
		_after_layout = TrackReorderCommand.capture_layout(project)
		return
	if channel and project.get_channel_by_id(channel.id) == null:
		project.add_channel(channel, track)
	if project.get_track_by_id(track.id) == null:
		project.add_track(track)
		var ch := project.get_track_mixer_channel(track)
		if ch:
			ch.register_track(track)
	project.apply_track_layout(_after_layout)


## Remove the copy (and its channel).
func undo() -> void:
	if project == null or track == null:
		return
	var ch := project.get_track_mixer_channel(track)
	if ch:
		# Unregister first: remove_channel would reroute a still-registered track to Master.
		ch.unregister_track(track)
	project.remove_track(track.id)
	if channel:
		project.remove_channel(channel.id)
	project.apply_track_layout(_before_layout)


func _create() -> void:
	var source_channel := project.get_track_mixer_channel(source)

	var data := source.to_json()
	# Routing and hierarchy are applied below, once the copy is attached to the project.
	data.erase("default_channel_id")
	data.erase("parent_track_id")
	data["child_track_ids"] = []
	data["id"] = project.next_track_id
	project.next_track_id += 1
	track = Track.from_json(data)
	for instance in track.clip_instances:
		instance.id = instance._generate_uuid()
		instance.clip = project.get_clip(instance.clip_id)
	track.name_by_channel = false
	track.color_by_channel = false
	track.set_color(source.get_color())
	track.name = project.unique_name(source.name)
	project.add_track(track)

	if with_channel and source_channel:
		channel = _copy_channel(source_channel)
		project.route_track_to_channel(track, channel)
	elif source_channel:
		project.route_track_to_channel(track, source_channel)

	project.place_track(track, source.parent_track_id, source)
	if channel and channel.parent_channel_id < 0 and source_channel.parent_channel_id < 0:
		# Not nested under a group: play into the same place the source strip does.
		channel.set_route(source_channel.output_channel_id)


## New channel with the source's settings, devices (fresh ids) and sends. Aux returns are not
## copied: they belong to the source's multi-out device.
func _copy_channel(source_channel: Channel) -> Channel:
	var data := source_channel.to_json()
	data["id"] = project.next_channel_id
	project.next_channel_id += 1
	data["parent_channel_id"] = -1
	data["child_channel_ids"] = []
	data["aux_bus_index"] = -1
	data["aux_pad_note"] = -1
	data["record_armed"] = false
	data["name"] = project.unique_name(track.name, track, null, "Channel")
	var devices: Array = data.get("devices", [])
	for device_data in devices:
		_refresh_device_ids(device_data, int(data["id"]))
	var copy := Channel.from_json(data)
	copy.output_channel_id = source_channel.output_channel_id
	project.add_channel(copy, track)
	return copy


## Give a serialized device tree new instance ids on `channel_id`, dropping aux return links.
func _refresh_device_ids(device_data: Dictionary, channel_id: int) -> void:
	device_data.erase("id")
	device_data["channel_id"] = channel_id
	device_data["return_channel_id"] = -1
	device_data["return_channel_ids"] = []
	for child_data in device_data.get("children", []):
		if child_data is Dictionary:
			_refresh_device_ids(child_data, channel_id)
