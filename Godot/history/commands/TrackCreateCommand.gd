# TrackCreateCommand.gd
# Undoable instrument/audio/folder track creation (keeps Track + Channel identity).
class_name TrackCreateCommand extends Command

## Project that owns the track/channel.
var project: Project = null

## Created track (set after first do, or passed if already created then recorded).
var track: Track = null

## Created channel (may be null for folder without channel).
var channel: Channel = null

## Creation kind: "instrument", "audio", "folder", or "group".
var kind: String = "instrument"

## Display name used when (re)creating.
var track_name: String = "Track"

## Whether folder creation includes a bus channel.
var folder_with_channel: bool = false


## Create a track-create command. If track/channel already exist, use record().
func _init(
	p_project: Project = null,
	p_kind: String = "instrument",
	p_name: String = "Track",
	p_track: Track = null,
	p_channel: Channel = null,
	p_folder_with_channel: bool = false
) -> void:
	project = p_project
	kind = p_kind
	track_name = p_name
	track = p_track
	channel = p_channel
	folder_with_channel = p_folder_with_channel
	match kind:
		"audio":
			name = "Create Audio Track"
		"folder":
			name = "Create Folder"
		"group":
			name = "Create Group Track"
			folder_with_channel = true
		_:
			name = "Create Instrument Track"


## Create (or re-add) the track and channel.
func do() -> void:
	if project == null:
		return
	if track != null:
		# Re-add existing objects
		if channel != null and project.get_channel_by_id(channel.id) == null:
			project.add_channel(channel)
		if project.get_track_by_id(track.id) == null:
			project.add_track(track)
		return

	var result: Dictionary
	match kind:
		"audio":
			result = project.create_audio_track(track_name)
		"folder":
			result = project.create_folder_track(track_name, folder_with_channel)
		"group":
			result = project.create_folder_track(track_name, true)
		_:
			result = project.create_instrument_track(track_name)
	track = result.get("track")
	channel = result.get("channel")


## Remove the track (and channel if present).
func undo() -> void:
	if project == null or track == null:
		return
	project.remove_track(track.id)
	if channel != null:
		project.remove_channel(channel.id)
